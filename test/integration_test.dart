import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/dart_analysis_daemon.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('dana-integration-');
    await File(
      '${project.path}${Platform.pathSeparator}pubspec.yaml',
    ).writeAsString(
      'name: dana_integration_fixture\n'
      'environment:\n'
      '  sdk: ">=3.7.0 <4.0.0"\n',
    );
    final pubGet = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: project.path);
    expect(
      pubGet.exitCode,
      0,
      reason: 'pub get failed: ${pubGet.stdout}${pubGet.stderr}',
    );
    final lib = Directory('${project.path}${Platform.pathSeparator}lib');
    await lib.create(recursive: true);
    await File(
      '${lib.path}${Platform.pathSeparator}main.dart',
    ).writeAsString('int answer = 42;\n');
  });

  tearDown(() async {
    final endpoint = File(
      '${project.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}ai-analyzer-session.json',
    );
    if (await endpoint.exists()) {
      await _run('stop', project.path);
    }
    // A detached session can retain its working-directory handle briefly
    // after acknowledging stop. Require eventual release on Windows.
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

  test('reuses a session and removes it on stop', () async {
    final file =
        '${project.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}main.dart';
    final first = await _run('check', project.path, [
      '--mode',
      'fast',
      '--files',
      file,
    ]);
    expect(first.exitCode, 0, reason: _details(first));
    final firstResponse = jsonDecode(first.stdout) as Map;
    expect(firstResponse['ok'], true);
    expect(firstResponse['errors'], 0);
    // Stage 1 scheduler observability: an owned session must tag its source so
    // callers can tell a daemon check apart from an IDE-bridge reuse.
    expect(firstResponse['source'], 'daemon-session');

    final full = await _run('check', project.path, ['--mode', 'full']);
    expect(full.exitCode, 0, reason: _details(full));
    final fullResponse = jsonDecode(full.stdout) as Map;
    expect(fullResponse['ok'], true);
    expect(fullResponse['source'], 'daemon-session');
    expect(fullResponse['mode'], 'full');

    final apiSession = await SessionClient.connect(project.path);
    try {
      final apiResult = await apiSession.checkFiles([file]);
      expect(apiResult['ok'], true);
      expect(apiResult['errors'], 0);
      final overlayResult = await apiSession.checkFiles(
        [file],
        overlays: {file: 'void main( {\n'},
      );
      expect(overlayResult['ok'], true);
      expect(overlayResult['errors'], greaterThan(0));
      expect((await apiSession.clearOverlays([file]))['ok'], true);
      final diskResult = await apiSession.checkFiles([file]);
      expect(diskResult['errors'], 0);
    } finally {
      await apiSession.close();
    }

    final status = await _run('status', project.path);
    expect(status.exitCode, 0, reason: _details(status));
    final statusResponse = jsonDecode(status.stdout) as Map;
    expect(statusResponse['started'], true);
    expect(statusResponse['source'], 'daemon-session');

    final second = await _run('check', project.path, [
      '--mode',
      'fast',
      '--files',
      file,
    ]);
    expect(second.exitCode, 0, reason: _details(second));
    expect((jsonDecode(second.stdout) as Map)['ok'], true);

    final stop = await _run('stop', project.path);
    expect(stop.exitCode, 0, reason: _details(stop));
    expect(
      await File(
        '${project.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}ai-analyzer-session.json',
      ).exists(),
      false,
    );
  });

  test('returns a non-zero exit code for a syntax error', () async {
    final file =
        '${project.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}main.dart';
    await File(file).writeAsString('void main( {\n');

    final result = await _run('check', project.path, [
      '--mode',
      'fast',
      '--files',
      file,
    ]);
    expect(result.exitCode, 1, reason: _details(result));
    expect((jsonDecode(result.stdout) as Map)['ok'], true);
  });

  test('returns a non-zero exit code for a failed check request', () async {
    final empty = Directory('${project.path}${Platform.pathSeparator}empty');
    await empty.create();

    final result = await _run('check', project.path, [
      '--mode',
      'fast',
      '--files',
      empty.path,
    ]);
    expect(result.exitCode, 1, reason: _details(result));
    expect((jsonDecode(result.stdout) as Map)['ok'], false);
  });

  test(
    'fast check expands directories and respects analyzer excludes',
    () async {
      final excluded = Directory(
        '${project.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}generated',
      );
      await excluded.create(recursive: true);
      final includedFile = File(
        '${project.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}included.dart',
      );
      final excludedFile = File(
        '${excluded.path}${Platform.pathSeparator}excluded.dart',
      );
      await includedFile.writeAsString('int included = 1;\n');
      await excludedFile.writeAsString('void broken( {\n');
      await File(
        '${project.path}${Platform.pathSeparator}analysis_options.yaml',
      ).writeAsString('analyzer:\n  exclude:\n    - lib/generated/**\n');

      final result = await _run('check', project.path, [
        '--mode',
        'fast',
        '--files',
        '${project.path}${Platform.pathSeparator}lib',
      ]);
      expect(result.exitCode, 0, reason: _details(result));
      final response = jsonDecode(result.stdout) as Map;
      final diagnostics = Map<Object?, Object?>.from(
        response['diagnostics'] as Map,
      );
      // dana reports canonical (symlink-resolved) paths, matching how it
      // canonicalizes the root. Resolve the fixture paths the same way before
      // comparing so the assertion holds on platforms where the temp dir is
      // itself a symlink (e.g. macOS `/var` -> `/private/var`).
      final includedCanonical = includedFile.resolveSymbolicLinksSync();
      final excludedCanonical = excludedFile.resolveSymbolicLinksSync();
      expect(diagnostics.keys.any((key) => '$key' == includedCanonical), true);
      expect(diagnostics.keys.any((key) => '$key' == excludedCanonical), false);
    },
  );

  test('coalesces concurrent first checks into one session', () async {
    final file =
        '${project.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}main.dart';
    final results = await Future.wait([
      _run('check', project.path, ['--mode', 'fast', '--files', file]),
      _run('check', project.path, ['--mode', 'fast', '--files', file]),
    ]);

    for (final result in results) {
      expect(result.exitCode, 0, reason: _details(result));
      expect((jsonDecode(result.stdout) as Map)['ok'], true);
    }
    final status = await _run('status', project.path);
    expect(status.exitCode, 0, reason: _details(status));
  });
}

Future<ProcessResult> _run(
  String command,
  String root, [
  List<String> arguments = const [],
]) => Process.run(
  Platform.resolvedExecutable,
  ['bin/dart_analysis_daemon.dart', command, '--root', root, ...arguments],
  workingDirectory: Directory.current.path,
  environment: {
    ...Platform.environment,
    'DANA_MULTI_ROOT': '0',
    'DANA_POOL_MAX_ROOTS': '3',
    'DANA_GLOBAL_BUDGET': '0',
  },
);

String _details(ProcessResult result) => '${result.stdout}${result.stderr}';
