import 'dart:async';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/session_client.dart';
import 'package:dart_analysis_daemon/src/session_server.dart';
import 'package:test/test.dart';

class _ControlledAnalyzer extends AnalyzerDaemon {
  _ControlledAnalyzer(super.root, {this.onStart, this.closeError});

  final Future<void> Function()? onStart;
  final Object? closeError;
  final entered = Completer<void>();
  final finish = Completer<void>();
  bool closed = false;
  final operations = <Object?>[];

  @override
  Future<void> start() async {
    await onStart?.call();
  }

  @override
  Future<Map<String, Object?>> handle(Map<String, Object?> command) async {
    operations.add(command['op']);
    if (command['op'] == 'check') {
      entered.complete();
      await finish.future;
    }
    return {'ok': true, 'started': true};
  }

  @override
  Future<void> close() async {
    closed = true;
    if (closeError != null) throw closeError!;
  }
}

Future<void> _waitForEndpoint(String root) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await endpointFile(root).exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Session did not publish its endpoint');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('idle cleanup failure is returned by serveSession', () async {
    final project = await Directory.systemTemp.createTemp('dana-idle-failure-');
    final root = await project.resolveSymbolicLinks();
    addTearDown(() => project.delete(recursive: true));
    final failure = StateError('Injected analyzer close failure');
    final analyzer = _ControlledAnalyzer(root, closeError: failure);
    await expectLater(
      serveSession(
        root,
        analyzer: analyzer,
        idleTimeout: const Duration(milliseconds: 100),
      ),
      throwsA(same(failure)),
    );
    expect(analyzer.closed, true);
    expect(await endpointFile(root).exists(), false);
  });

  test('endpoint publication failure closes the started analyzer', () async {
    final project = await Directory.systemTemp.createTemp('dana-idle-publish-');
    final root = await project.resolveSymbolicLinks();
    addTearDown(() => project.delete(recursive: true));
    final analyzer = _ControlledAnalyzer(
      root,
      onStart: () async {
        // An exact-path directory prevents publishing the endpoint file.
        await Directory(endpointFile(root).path).create();
      },
    );
    await expectLater(
      serveSession(root, analyzer: analyzer),
      throwsA(isA<FileSystemException>()),
    );
    expect(analyzer.closed, true);
    // Publication failure must also release the startup lock for recovery.
    await Directory(endpointFile(root).path).delete();
    final replacement = _ControlledAnalyzer(root);
    await serveSession(
      root,
      analyzer: replacement,
      idleTimeout: const Duration(milliseconds: 100),
    ).timeout(const Duration(seconds: 5));
    expect(replacement.closed, true);
    expect(await endpointFile(root).exists(), false);
  });

  test(
    'API clients hold sessions; idle close allows a fresh session',
    () async {
      final project = await Directory.systemTemp.createTemp('dana-idle-api-');
      final root = await project.resolveSymbolicLinks();
      addTearDown(() => project.delete(recursive: true));
      for (var generation = 0; generation < 2; generation++) {
        final analyzer = _ControlledAnalyzer(root);
        final serving = serveSession(
          root,
          idleTimeout: const Duration(milliseconds: 300),
          analyzer: analyzer,
        );
        await _waitForEndpoint(root);
        final client = await SessionClient.connect(root, autoStart: false);
        try {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(analyzer.closed, false);
          expect((await client.status())['idleTimeoutSeconds'], 0);
        } finally {
          await client.close();
        }
        await serving.timeout(const Duration(seconds: 5));
        expect(analyzer.closed, true);
        expect(await endpointFile(root).exists(), false);
      }
    },
  );

  test('socket disconnect cannot reclaim an in-flight exchange', () async {
    final project = await Directory.systemTemp.createTemp('dana-idle-drain-');
    final root = await project.resolveSymbolicLinks();
    addTearDown(() => project.delete(recursive: true));
    final analyzer = _ControlledAnalyzer(root);
    final serving = serveSession(
      root,
      idleTimeout: const Duration(milliseconds: 300),
      analyzer: analyzer,
    );
    await _waitForEndpoint(root);
    final connection =
        (await connectOrStartSession(
          root,
          endpointFile(root),
          autoStart: false,
        ))!;
    connection.$1.writeln(
      '{"token":"${connection.$2}","op":"check","files":["probe.dart"]}',
    );
    await connection.$1.flush();
    await analyzer.entered.future.timeout(const Duration(seconds: 5));
    final queued =
        (await connectOrStartSession(
          root,
          endpointFile(root),
          autoStart: false,
        ))!;
    queued.$1.writeln('{"token":"${queued.$2}","op":"status"}');
    await queued.$1.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    connection.$1.destroy();
    queued.$1.destroy();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(analyzer.closed, false);
      expect(await endpointFile(root).exists(), true);
    } finally {
      analyzer.finish.complete();
    }
    await serving.timeout(const Duration(seconds: 5));
    expect(analyzer.operations, ['check', 'status']);
    expect(analyzer.closed, true);
    expect(await endpointFile(root).exists(), false);
  });
}
