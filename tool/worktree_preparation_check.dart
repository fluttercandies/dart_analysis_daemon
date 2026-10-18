import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_manager_probe_check.dart' show Client, check, poll;

// Socket + native Job integration, using only lightweight synthetic workers.
Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-preparation-');
  final root = await Directory('${fixture.path}/root').create();
  final options = File('${root.path}/analysis_options.yaml');
  await options.writeAsString(
    'analyzer:\n  errors:\n    unused_import: warning\n',
  );
  final process = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--environment-identity',
    '--lifecycle-injections',
    '--short-connections',
  ]);
  final ready = Completer<void>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (!ready.isCompleted && jsonDecode(line)['event'] == 'ready') {
        ready.complete();
      }
    },
  );
  process.stderr.transform(utf8.decoder).listen(stderr.write);
  final clients = <Client>[];
  final results = <Map>[];
  try {
    await ready.future.timeout(const Duration(seconds: 15));
    final metadata =
        jsonDecode(await File('${fixture.path}/manager.json').readAsString())
            as Map;
    Future<Client> connect() async {
      final client = await Client.connect(metadata);
      clients.add(client);
      return client;
    }

    final admin = await connect();
    // Keep only this control connection alive while other idle timers are tested.
    final heartbeat = Timer.periodic(const Duration(milliseconds: 100), (_) {
      unawaited(
        admin.send('status').then<void>((_) {}, onError: (Object _) {}),
      );
    });
    try {
      Future<void> policy(int prepare, int start) async {
        check(
          (await admin.send(
                'research-lifecycle',
                fields: {
                  'preparationDelayMs': prepare,
                  'startupDelayMs': start,
                },
              ))['ok'] ==
              true,
          'Injection rejected',
        );
      }

      Future<Map> work(Client client, {int timeout = 20000}) => client.send(
        'check',
        fields: {'root': root.path, 'workMs': 10, 'timeoutMs': timeout},
      );
      Future<void> run(String name, Future<void> Function() body) async {
        final watch = Stopwatch()..start();
        await body().timeout(const Duration(seconds: 30));
        results.add({
          'name': name,
          'passed': true,
          'durationMs': watch.elapsedMilliseconds,
        });
        print('PASS $name');
      }

      Future<void> empty() => poll(() async {
        final status = await admin.send('status');
        return status['slots'] == 0 &&
            status['outstanding'] == 0 &&
            status['preparing'] == 0;
      });
      await run(
        'cancel during preparation is found terminal once and starts no worker',
        () async {
          await policy(1500, 0);
          final client = await connect();
          final pending = work(client);
          final id = '${client.sequence}';
          await poll(
            () async => (await admin.send('status'))['preparing'] == 1,
          );
          check(
            (await client.send('cancel', fields: {'target': id}))['found'] ==
                true,
            'Preparing request invisible',
          );
          check((await pending)['ok'] == false, 'Cancelled request succeeded');
          await empty();
          check(
            client.counts[id] == 1 &&
                (await admin.send('status'))['nativeAttempts'] == 0,
            'Terminal duplicate or worker created',
          );
        },
      );
      await run(
        'preparation deadline cleans counters without creating worker',
        () async {
          final client = await connect();
          check(
            (await work(client, timeout: 200))['ok'] == false,
            'Deadline ignored',
          );
          await empty();
          check(
            (await admin.send('status'))['nativeAttempts'] == 0,
            'Expired request started worker',
          );
        },
      );
      await run(
        'disconnect during preparation releases request without starting worker',
        () async {
          final client = await connect();
          final pending = work(client);
          final observed = pending.then<void>((_) {}, onError: (Object _) {});
          await poll(
            () async => (await admin.send('status'))['preparing'] == 1,
          );
          client.close();
          await observed;
          await empty();
          check(
            (await admin.send('status'))['nativeAttempts'] == 0,
            'Disconnected request started worker',
          );
        },
      );
      await run(
        'pending preparation protects connection from short idle timeout',
        () async {
          await policy(800, 0);
          final client = await connect();
          check(
            (await work(client))['ok'] == true,
            'Pending connection timed out',
          );
          check(
            (await admin.send('status'))['starts'] == 1,
            'Expected one worker',
          );
          await admin.send(
            'research-policy',
            fields: {'idleMs': 100, 'pressure': false},
          );
          await empty();
        },
      );
      await run(
        'configuration change during startup rejects old environment and replacement follows Job cleanup',
        () async {
          await policy(0, 1800);
          final client = await connect();
          final previousLogs = fixture.listSync().map((f) => f.path).toSet();
          final pending = work(client);
          await poll(
            () async => fixture.listSync().whereType<File>().any(
              (f) =>
                  !previousLogs.contains(f.path) &&
                  f.path.endsWith('.jsonl') &&
                  f.readAsStringSync().contains('"event":"leaf"'),
            ),
          );
          await options.writeAsString(
            'analyzer:\n  errors:\n    unused_import: error\n',
          );
          final rejected = await pending;
          check(
            rejected['ok'] == false &&
                '${rejected['error']}'.contains('during worker startup'),
            'Startup change not detected: $rejected',
          );
          await empty();
          await policy(0, 0);
          final replacement = await connect();
          check((await work(replacement))['ok'] == true, 'Replacement failed');
          final status = await admin.send('status');
          check(
            status['nativeAttempts'] == 3 &&
                status['starts'] == 2 &&
                status['degraded'] == null,
            'Cleanup or attempt accounting failed: $status',
          );
          await empty();
        },
      );
      await run(
        'all waiters cancelled during native startup leave no resident tree',
        () async {
          await policy(0, 1800);
          final client = await connect();
          final pending = work(client);
          final id = '${client.sequence}';
          await poll(
            () async => (await admin.send('status'))['nativeAttempts'] == 4,
          );
          check(
            (await client.send('cancel', fields: {'target': id}))['found'] ==
                true,
            'Starting cancellation missing',
          );
          check((await pending)['ok'] == false, 'Cancelled startup succeeded');
          await empty();
          check(
            (await admin.send('status'))['degraded'] == null,
            'Cleanup degraded',
          );
        },
      );
      await admin.send('shutdown');
      check(
        await process.exitCode.timeout(const Duration(seconds: 25)) == 0,
        'Shutdown failed',
      );
    } finally {
      heartbeat.cancel();
    }
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
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      process.kill();
    }
  }
}
