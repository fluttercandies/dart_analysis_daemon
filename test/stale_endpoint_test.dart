import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/session_server.dart';
import 'package:test/test.dart';

/// A session killed with SIGKILL leaves its endpoint file behind. The starter
/// refuses to launch while an endpoint exists, so if the client never removed
/// a dead one, every `dana check` would wait out the whole analysis timeout.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dana-stale-endpoint-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<int> deadPort() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  // A pid that is free on this machine: far above typical pid ranges, and
  // checked with `kill -0` so the test does not silently pass on a reuse.
  int freePid() {
    if (Platform.isWindows) {
      // Use a process we own and have already reaped. The runtime checks its
      // absence through OpenProcess/GetExitCodeProcess on Windows.
      final child = Process.runSync(Platform.resolvedExecutable, ['--version']);
      expect(child.exitCode, 0);
      return child.pid;
    }
    for (var candidate = 99999; candidate < 99999 + 5000; candidate++) {
      final probe = Process.runSync('/bin/kill', ['-0', '$candidate']);
      if (probe.exitCode != 0 &&
          '${probe.stderr}'.toLowerCase().contains('no such process')) {
        return candidate;
      }
    }
    throw StateError('no free pid found');
  }

  Future<File> writeEndpoint(int port, {int? ownerPid}) async {
    final canonical = root.resolveSymbolicLinksSync();
    final endpoint = endpointFile(canonical);
    await endpoint.parent.create(recursive: true);
    await endpoint.writeAsString(
      jsonEncode({
        'protocol': 1,
        'root': canonical,
        'address': '127.0.0.1',
        'port': port,
        'token': 'dead',
        'pid': ownerPid ?? freePid(),
        'owner': 'dart_analysis_daemon',
        'identity': await sessionIdentity(canonical),
      }),
    );
    return endpoint;
  }

  test('an endpoint whose port refuses connections is removed', () async {
    final endpoint = await writeEndpoint(await deadPort());
    final connection = await connectOrStartSession(
      root.resolveSymbolicLinksSync(),
      endpoint,
      autoStart: false,
    );
    expect(connection, isNull);
    expect(await endpoint.exists(), isFalse);
  });

  test(
    'a refused endpoint whose owner is alive is kept (still closing)',
    () async {
      final endpoint = await writeEndpoint(await deadPort(), ownerPid: pid);
      final connection = await connectOrStartSession(
        root.resolveSymbolicLinksSync(),
        endpoint,
        autoStart: false,
      );
      expect(connection, isNull);
      expect(await endpoint.exists(), isTrue);
    },
  );

  test('a live endpoint is kept and connected to', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) => socket.destroy());
    final endpoint = await writeEndpoint(server.port);
    final connection = await connectOrStartSession(
      root.resolveSymbolicLinksSync(),
      endpoint,
      autoStart: false,
    );
    expect(connection, isNotNull);
    connection!.$1.destroy();
    expect(await endpoint.exists(), isTrue);
  });

  group('an endpoint with a foreign identity', () {
    late ServerSocket server;
    late File endpoint;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) => socket.destroy());
      endpoint = await writeEndpoint(server.port);
      final metadata = jsonDecode(await endpoint.readAsString()) as Map;
      metadata['identity'] = {'dartExecutable': 'another-sdk'};
      await endpoint.writeAsString(jsonEncode(metadata));
    });

    tearDown(() => server.close());

    test('is refused for analysis', () async {
      final connection = await connectOrStartSession(
        root.resolveSymbolicLinksSync(),
        endpoint,
        autoStart: false,
      );
      expect(connection, isNull);
      expect(await endpoint.exists(), isTrue);
    });

    test('is still reachable for shutdown', () async {
      final connection = await connectOrStartSession(
        root.resolveSymbolicLinksSync(),
        endpoint,
        autoStart: false,
        requireIdentity: false,
      );
      expect(connection, isNotNull);
      expect(connection!.$2, 'dead');
      connection.$1.destroy();
    });
  });
}
