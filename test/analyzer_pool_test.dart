import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_pool.dart';
import 'package:test/test.dart';

/// Unit coverage for the shared-pool discovery layer. End-to-end auto-join (a
/// second `dana check` joining the first project's pool) is verified with real
/// CLI commands; these tests pin the discovery/registry/identity logic that
/// routing depends on, with an injected registry file and fake loopback servers
/// so no analyzer process is started.
void main() {
  late Directory tempDir;
  late File registry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dana-pool-unit-');
    registry = File('${tempDir.path}${Platform.pathSeparator}pool.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  PoolRegistration registrationFor(int port) => PoolRegistration(
    address: '127.0.0.1',
    port: port,
    token: 'tok',
    pid: 4242,
    roots: ['/abs/A'],
    identity: const {'protocol': 1, 'sdk': 'x'},
  );

  test('write then discover round-trips a live pool', () async {
    // A reachable listener whose identity matches the discovery identity.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final identity = await poolIdentity();
    await writePoolRegistry(
      PoolRegistration(
        address: '127.0.0.1',
        port: server.port,
        token: 'tok',
        pid: 4242,
        roots: ['/abs/A'],
        identity: identity,
      ),
      registry: registry,
    );

    final found = await discoverPool(registry: registry);
    expect(found, isNotNull);
    expect(found!.port, server.port);
    expect(found.roots, ['/abs/A']);
  });

  test('probing a live pool does not keep the caller process alive', () async {
    // The pool listener accepts and holds every connection open, as a real
    // session does until the client hangs up.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    server.listen(held.add);
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await server.close();
    });
    await writePoolRegistry(
      PoolRegistration(
        address: '127.0.0.1',
        port: server.port,
        token: 'tok',
        pid: 4242,
        roots: ['/abs/A'],
        identity: await poolIdentity(),
      ),
      registry: registry,
    );
    final script = File('${tempDir.path}${Platform.pathSeparator}probe.dart')
      ..writeAsStringSync('''
import 'dart:io';
import 'package:dart_analysis_daemon/src/analyzer_pool.dart';
Future<void> main(List<String> args) async {
  final found = await discoverPool(registry: File(args.single));
  stdout.writeln(found == null ? 'none' : 'found');
}
''');
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      script.path,
      registry.path,
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    expect(exitCode, 0, reason: 'process did not exit: ${await errors}');
    expect((await output).trim(), 'found');
  });

  group('parsePoolMaxRoots', () {
    test('defaults when unset', () {
      expect(parsePoolMaxRoots(null), defaultPoolMaxRoots);
      expect(parsePoolMaxRoots(''), defaultPoolMaxRoots);
    });
    test('accepts 1..64', () {
      expect(parsePoolMaxRoots('1'), 1);
      expect(parsePoolMaxRoots('64'), 64);
    });
    for (final bad in ['0', '65', '-1', '2.5', ' 3', 'many']) {
      test('rejects "$bad"', () {
        expect(() => parsePoolMaxRoots(bad), throwsFormatException);
      });
    }
  });

  group('poolRootsChanged', () {
    test('a join or leave that changed the root set republishes', () {
      expect(
        poolRootsChanged({'op': 'addRoot'}, {'ok': true, 'changed': true}),
        isTrue,
      );
      expect(
        poolRootsChanged({'op': 'removeRoot'}, {'ok': true, 'changed': true}),
        isTrue,
      );
    });
    test('an eviction alone republishes', () {
      expect(
        poolRootsChanged(
          {'op': 'addRoot'},
          {
            'ok': true,
            'changed': false,
            'evicted': ['/b'],
          },
        ),
        isTrue,
      );
    });
    test('eviction is republished even when the requested root is denied', () {
      expect(
        poolRootsChanged(
          {'op': 'addRoot'},
          {
            'ok': false,
            'code': 'pool-admission-denied',
            'changed': false,
            'evicted': ['/b'],
          },
        ),
        isTrue,
      );
    });
    test('no-op, failed or unrelated commands do not', () {
      expect(
        poolRootsChanged(
          {'op': 'addRoot'},
          {'ok': true, 'changed': false, 'evicted': <String>[]},
        ),
        isFalse,
      );
      expect(
        poolRootsChanged({'op': 'addRoot'}, {'ok': false, 'changed': true}),
        isFalse,
      );
      expect(
        poolRootsChanged({'op': 'check'}, {'ok': true, 'changed': true}),
        isFalse,
      );
    });
  });

  test('PoolClient.fullCheck scopes the request to a root', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final received = Completer<Map<String, Object?>>();
    server.listen((socket) {
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            received.complete(jsonDecode(line) as Map<String, Object?>);
            socket.writeln(jsonEncode({'ok': true}));
          });
    });
    final client = await PoolClient.connect(registrationFor(server.port));
    addTearDown(client.close);
    await client.fullCheck(root: '/abs/B');
    final command = await received.future;
    expect(command['op'], 'fullCheck');
    expect(command['root'], '/abs/B');
  });

  test('discover returns null when the registry is absent', () async {
    expect(await discoverPool(registry: registry), isNull);
  });

  test('discover returns null for an unreachable (dead) pool', () async {
    // Bind then immediately release the port so nothing is listening. Use the
    // real identity so the gate passes and the null result is due solely to
    // unreachability, not an identity mismatch.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = server.port;
    await server.close();
    final identity = await poolIdentity();
    await writePoolRegistry(
      PoolRegistration(
        address: '127.0.0.1',
        port: deadPort,
        token: 'tok',
        pid: 4242,
        roots: const ['/abs/A'],
        identity: identity,
      ),
      registry: registry,
    );
    expect(await discoverPool(registry: registry), isNull);
  });

  test('discover returns null when identity differs', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    // Registry records a different identity than the current SDK's.
    await writePoolRegistry(registrationFor(server.port), registry: registry);
    expect(
      await discoverPool(registry: registry),
      isNull,
      reason: 'a pool on a different identity must not be joined',
    );
  });

  test(
    'deletePoolRegistryIfOwned only removes this process registry',
    () async {
      // Owned by another pid: must be left in place.
      await writePoolRegistry(registrationFor(1), registry: registry);
      await deletePoolRegistryIfOwned(registry: registry);
      expect(await registry.exists(), true);
    },
  );

  test('PoolClient.addRoot sends an authenticated addRoot command', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final received = Completer<Map<String, Object?>>();
    server.listen((socket) {
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final command = jsonDecode(line) as Map<String, Object?>;
            if (!received.isCompleted) received.complete(command);
            socket.writeln(jsonEncode({'ok': true, 'changed': true}));
            socket.flush();
          });
    });

    final client = await PoolClient.connect(registrationFor(server.port));
    addTearDown(() => client.close());
    final response = await client.addRoot('/abs/B');
    expect(response['ok'], true);
    expect(response['changed'], true);

    final command = await received.future;
    expect(command['op'], 'addRoot');
    expect(command['root'], '/abs/B');
    expect(command['token'], 'tok');
  });
}
