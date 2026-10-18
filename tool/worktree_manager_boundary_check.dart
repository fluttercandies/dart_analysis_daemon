// Separate lightweight boundary suite; no analyzer is started.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'worktree_manager_probe_check.dart' show Client, check, poll;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp(
    'dana-manager-boundary-',
  );
  final root = await Directory('${fixture.path}/root').create();
  final processes = <Process>[];
  final clients = <Client>[];
  final outputs = <Process, Future<String>>{};
  final firstEvents = <Process, Completer<Map>>{};
  final results = <Map<String, Object?>>[];
  Future<Process> start([List<String> flags = const []]) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
      fixture.path,
      ...flags,
    ]);
    processes.add(process);
    unawaited(process.stderr.drain<void>());
    final first = firstEvents[process] = Completer<Map>();
    final output = StringBuffer();
    final done = Completer<String>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            output.writeln(line);
            if (!first.isCompleted) first.complete(jsonDecode(line) as Map);
          },
          onDone: () {
            done.complete(output.toString());
          },
        );
    outputs[process] = done.future;
    return process;
  }

  Future<void> run(String name, Future<void> Function() body) async {
    final clock = Stopwatch()..start();
    await body().timeout(const Duration(seconds: 30));
    results.add({
      'name': name,
      'passed': true,
      'durationMs': clock.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  Future<Map> metadata() async =>
      jsonDecode(await File('${fixture.path}/manager.json').readAsString())
          as Map;
  Future<Client> connect(Map data) async {
    final client = await Client.connect(data);
    clients.add(client);
    return client;
  }

  Future<void> rawDisconnect(Map data, List<int> bytes) async {
    final socket = await Socket.connect('127.0.0.1', data['port'] as int);
    final ended = socket.drain<void>();
    socket.add(bytes);
    await socket.flush();
    await ended.timeout(const Duration(seconds: 5));
    socket.destroy();
  }

  try {
    for (final failurePoint in ['--fail-publish', '--fail-after-publish']) {
      await run(
        '$failurePoint closes socket sampler temp file and lifetime lock',
        () async {
          final process = await start(['--system-memory', failurePoint]);
          final output = await outputs[process]!;
          check(
            await process.exitCode != 0,
            'Injected setup failure succeeded',
          );
          final failed = jsonDecode(output.trim()) as Map;
          check(
            failed['event'] == 'publish-failure' && failed['samplerPid'] is int,
            'Failure did not reach resource setup',
          );
          var refused = false;
          try {
            final socket = await Socket.connect(
              '127.0.0.1',
              failed['port'] as int,
            );
            socket.destroy();
          } on SocketException {
            refused = true;
          }
          check(refused, 'Failed startup left bound listener');
          check(
            !await File('${fixture.path}/manager.json').exists(),
            'Failed endpoint published',
          );
          check(
            !(await fixture.list().toList()).any(
              (f) => f.path.endsWith('.tmp'),
            ),
            'Temporary endpoint leaked',
          );
        },
      );
    }
    late Map data;
    late Process winner;
    await run(
      'simultaneous first starters elect exactly one manager',
      () async {
        final contenders = await Future.wait([start(), start()]);
        final first = await Future.wait([
          for (final process in contenders)
            firstEvents[process]!.future.timeout(const Duration(seconds: 10)),
        ]);
        check(
          first.where((e) => e['event'] == 'ready').length == 1 &&
              first.where((e) => e['event'] == 'already-running').length == 1,
          'Startup election failed',
        );
        final winnerIndex = first.indexWhere((e) => e['event'] == 'ready');
        winner = contenders[winnerIndex];
        check(
          await contenders[1 - winnerIndex].exitCode == 0,
          'Competing starter failed unexpectedly',
        );
        data = await metadata();
        check(
          data['pid'] == first[winnerIndex]['pid'],
          'Endpoint does not identify winner',
        );
      },
    );
    final admin = await connect(data);
    await run(
      'oversized unterminated frame and invalid UTF8 close only offending connection',
      () async {
        await rawDisconnect(data, List.filled(65537, 65));
        await rawDisconnect(data, [0xff, 10]);
        check(
          (await admin.send('status'))['ok'] == true,
          'Malformed frame damaged manager',
        );
      },
    );
    await run(
      'duplicate active request ID disconnects and releases all its leases',
      () async {
        final client = await connect(data);
        final work = client
            .send(
              'check',
              fields: {'root': root.path, 'workMs': 10000, 'timeoutMs': 15000},
            )
            .then((_) => false, onError: (Object _) => true);
        final id = '${client.sequence}';
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        client.socket.writeln(jsonEncode({...data, 'id': id, 'op': 'status'}));
        check(await work, 'Duplicate request remained connected');
        check(
          (client.counts[id] ?? 0) <= 1,
          'Duplicate ID produced multiple terminal responses',
        );
        await poll(() async => (await admin.send('status'))['leases'] == 0);
      },
    );
    await run(
      'per-connection outstanding requests are bounded and overflow has a terminal response',
      () async {
        await admin.send('memory', fields: {'allowed': false});
        // Retire the previous idle worker so the following root cannot reuse it.
        final other = await Directory('${fixture.path}/other').create();
        final client = await connect(data);
        final pending = [
          for (var i = 0; i < 64; i++)
            client
                .send(
                  'check',
                  fields: {'root': other.path, 'workMs': 1, 'timeoutMs': 15000},
                )
                .then((_) {}, onError: (Object _) {}),
        ];
        await poll(() async => (await admin.send('status'))['queued'] == 64);
        final overflow = await client.send(
          'check',
          fields: {'root': other.path, 'workMs': 1, 'timeoutMs': 15000},
        );
        check(
          overflow['ok'] == false &&
              '${overflow['error']}'.contains('Too many'),
          'Outstanding limit bypassed',
        );
        client.close();
        await Future.wait(pending);
        await poll(() async => (await admin.send('status'))['queued'] == 0);
        await admin.send('memory', fields: {'allowed': true});
      },
    );
    await run(
      'global outstanding requests are bounded across clients',
      () async {
        await admin.send('memory', fields: {'allowed': false});
        final batchClients = <Client>[];
        final pending = <Future<void>>[];
        for (var c = 0; c < 4; c++) {
          final client = await connect(data);
          batchClients.add(client);
          for (var i = 0; i < 64; i++) {
            pending.add(
              client
                  .send(
                    'check',
                    fields: {
                      'root': root.path,
                      'workMs': 0,
                      'timeoutMs': 15000,
                    },
                  )
                  .then((_) {}, onError: (Object _) {}),
            );
          }
        }
        await poll(() async => (await admin.send('status'))['queued'] == 256);
        final overflow = await admin.send(
          'check',
          fields: {'root': root.path, 'workMs': 0, 'timeoutMs': 15000},
        );
        check(
          overflow['ok'] == false &&
              '${overflow['error']}'.contains('Too many'),
          'Global queue limit bypassed',
        );
        for (final client in batchClients) {
          client.close();
        }
        await Future.wait(pending);
        await poll(() async => (await admin.send('status'))['queued'] == 0);
        await admin.send('memory', fields: {'allowed': true});
      },
    );
    await run('large path errors have a bounded terminal response', () async {
      final response = await admin.send(
        'check',
        fields: {
          'root': 'C:\\${List.filled(10000, 'x').join()}',
          'workMs': 0,
          'timeoutMs': 100,
        },
      );
      check(
        response['ok'] == false &&
            response['error'] == 'Response exceeds research limit',
        'Oversized response not replaced',
      );
    });
    await run('connection request ID history is bounded', () async {
      final client = await connect(data);
      for (var i = 0; i < 1024; i++) {
        check(
          (await client.send('hello'))['ok'] == true,
          'Valid request rejected before limit',
        );
      }
      var disconnected = false;
      try {
        await client.send('hello');
      } on StateError {
        disconnected = true;
      }
      check(disconnected, 'ID history grew beyond limit');
    });
    await run(
      'connection count is bounded and excess sockets cannot affect manager',
      () async {
        final held = <Socket>[];
        try {
          // Admin is the only connected client at this point.
          await poll(() async => (await admin.send('status'))['clients'] == 1);
          for (var i = 0; i < 31; i++) {
            held.add(await Socket.connect('127.0.0.1', data['port'] as int));
          }
          await poll(() async => (await admin.send('status'))['clients'] == 32);
          await rawDisconnect(data, utf8.encode('{}\n'));
          check(
            (await admin.send('status'))['clients'] == 32,
            'Connection limit bypassed',
          );
        } finally {
          for (final socket in held) {
            socket.destroy();
          }
        }
      },
    );
    await run(
      'shutdown preserves a foreign generation endpoint and replacement can acquire lock',
      () async {
        final endpoint = File('${fixture.path}/manager.json');
        await endpoint.writeAsString(
          jsonEncode({...data, 'generation': 'foreign-record'}),
          flush: true,
        );
        await admin.send('shutdown');
        check(
          await winner.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Manager shutdown failed',
        );
        check(
          (await metadata())['generation'] == 'foreign-record',
          'Cleanup deleted foreign endpoint',
        );
        final replacement = await start();
        check(
          (await firstEvents[replacement]!.future)['event'] == 'ready',
          'Replacement did not start',
        );
        await poll(
          () async => (await metadata())['generation'] != 'foreign-record',
        );
        final newData = await metadata();
        check(
          newData['generation'] != 'foreign-record',
          'Foreign record was reused',
        );
        final replacementClient = await connect(newData);
        await replacementClient.send('shutdown');
        check(
          await replacement.exitCode.timeout(const Duration(seconds: 25)) ==
                  0 &&
              !await endpoint.exists(),
          'Replacement cleanup failed',
        );
      },
    );
    for (final corruption in ['malformed', 'oversized', 'wrong owner']) {
      await run(
        '$corruption endpoint is preserved on exit and replaced only by next lock owner',
        () async {
          final endpoint = File('${fixture.path}/manager.json');
          final manager = await start();
          check(
            (await firstEvents[manager]!.future)['event'] == 'ready',
            'Manager missing',
          );
          final record = await metadata();
          final client = await connect(record);
          final content = switch (corruption) {
            'malformed' => '{broken',
            'oversized' => List.filled(4097, 'x').join(),
            _ => jsonEncode({...record, 'owner': 'foreign-owner'}),
          };
          await endpoint.writeAsString(content, flush: true);
          await client.send('shutdown');
          check(
            await manager.exitCode.timeout(const Duration(seconds: 25)) == 0,
            'Corrupt record blocked shutdown',
          );
          check(
            await endpoint.readAsString() == content,
            'Unknown endpoint deleted',
          );
          final replacement = await start();
          check(
            (await firstEvents[replacement]!.future)['event'] == 'ready',
            'Replacement blocked by unknown record',
          );
          final replacementClient = await connect(await metadata());
          await replacementClient.send('shutdown');
          check(
            await replacement.exitCode.timeout(const Duration(seconds: 25)) ==
                    0 &&
                !await endpoint.exists(),
            'Replacement cleanup failed',
          );
        },
      );
    }
    final report = {
      'results': results,
      'fixture': fixture.path,
      'allPassed': true,
    };
    await File(
      '${fixture.path}/boundary-results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(jsonEncode(report));
  } finally {
    for (final client in clients) {
      client.close();
    }
    for (final process in processes) {
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 25));
      } on TimeoutException {
        process.kill();
      }
    }
  }
}
