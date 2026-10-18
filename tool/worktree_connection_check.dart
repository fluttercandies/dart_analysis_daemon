import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_manager_probe_check.dart' show Client, check, poll;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-connection-');
  final root = await Directory('${fixture.path}/root').create();
  final process = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--short-connections',
  ]);
  final ready = Completer<void>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (jsonDecode(line)['event'] == 'ready' && !ready.isCompleted) {
        ready.complete();
      }
    },
  );
  unawaited(process.stderr.drain<void>());
  final clients = <Client>[];
  final sockets = <Socket>[];
  final results = <Map>[];
  Future<void> run(String name, Future<void> Function() body) async {
    final clock = Stopwatch()..start();
    await body().timeout(const Duration(seconds: 20));
    results.add({
      'name': name,
      'passed': true,
      'durationMs': clock.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  try {
    await ready.future.timeout(const Duration(seconds: 10));
    final metadata =
        jsonDecode(await File('${fixture.path}/manager.json').readAsString())
            as Map;
    Future<Client> connect() async {
      final client = await Client.connect(metadata);
      clients.add(client);
      return client;
    }

    Future<Socket> raw() async {
      final socket = await Socket.connect('127.0.0.1', metadata['port'] as int);
      sockets.add(socket);
      return socket;
    }

    await run('silent and partial unauthenticated frames expire', () async {
      for (final partial in [false, true]) {
        final socket = await raw();
        final ended = socket.drain<void>();
        if (partial) {
          socket.add(utf8.encode('{"id":'));
          await socket.flush();
        }
        await ended.timeout(const Duration(seconds: 2));
      }
    });
    await run(
      'wrong credentials cannot extend authentication deadline',
      () async {
        final socket = await raw();
        final ended = Completer<void>();
        socket.listen(
          (_) {},
          onDone: () {
            ended.complete();
          },
        );
        final timer = Timer.periodic(const Duration(milliseconds: 40), (_) {
          socket.writeln(
            jsonEncode({
              ...metadata,
              'id': 'wrong',
              'token': 'incorrect',
              'op': 'hello',
            }),
          );
        });
        try {
          await ended.future.timeout(const Duration(seconds: 2));
        } finally {
          timer.cancel();
        }
      },
    );
    await run('authenticated idle connection expires', () async {
      final client = await connect();
      check((await client.send('hello'))['ok'] == true, 'Handshake failed');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      var closed = false;
      try {
        await client.send('hello');
      } on StateError {
        closed = true;
      }
      check(closed, 'Idle client remained connected');
    });
    await run(
      'queued and active requests survive idle deadline then connection expires after completion',
      () async {
        final admin = await connect();
        final keepalive = Timer.periodic(const Duration(milliseconds: 80), (_) {
          unawaited(admin.send('status').then((_) {}, onError: (Object _) {}));
        });
        try {
          await admin.send('memory', fields: {'allowed': false});
          final client = await connect();
          final work = client.send(
            'check',
            fields: {'root': root.path, 'workMs': 700, 'timeoutMs': 15000},
          );
          await poll(() async => (await admin.send('status'))['queued'] == 1);
          await Future<void>.delayed(const Duration(milliseconds: 650));
          check(
            (await admin.send('status'))['queued'] == 1,
            'Idle timer cancelled queued request',
          );
          await admin.send('memory', fields: {'allowed': true});
          check(
            (await work)['ok'] == true,
            'Idle timer cancelled starting/active request',
          );
          await Future<void>.delayed(const Duration(milliseconds: 600));
          var closed = false;
          try {
            await client.send('hello');
          } on StateError {
            closed = true;
          }
          check(closed, 'Finished request prevented idle expiry');
          await admin.send('shutdown');
        } finally {
          keepalive.cancel();
        }
      },
    );
    check(
      await process.exitCode.timeout(const Duration(seconds: 25)) == 0,
      'Manager cleanup failed',
    );
    final report = {
      'results': results,
      'fixture': fixture.path,
      'allPassed': true,
    };
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(jsonEncode(report));
  } finally {
    for (final client in clients) {
      client.close();
    }
    for (final socket in sockets) {
      socket.destroy();
    }
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      process.kill();
    }
  }
}
