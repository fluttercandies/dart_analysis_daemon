// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'worktree_manager_probe_check.dart' show Client, check, poll;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-overlay-');
  final roots = [
    for (var i = 0; i < 2; i++)
      await Directory('${fixture.path}/root$i').create(),
  ];
  final process = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--environment-identity',
    '--overlays',
    '--lifecycle-injections',
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

    final client = await connect();
    final admin = await connect();
    Future<Map> update(
      Client c,
      String path,
      int version,
      String? content, {
      int root = 0,
    }) => c.send(
      'overlay',
      fields: {
        'root': roots[root].path,
        'path': path,
        'version': version,
        'content': content,
      },
    );
    Future<Map> work(
      Client c, {
      int root = 0,
      int duration = 10,
      int timeout = 20000,
    }) => c.send(
      'check',
      fields: {
        'root': roots[root].path,
        'workMs': duration,
        'timeoutMs': timeout,
      },
    );
    Future<void> delay(int ms) async {
      check(
        (await admin.send(
              'research-lifecycle',
              fields: {
                'preparationDelayMs': 0,
                'startupDelayMs': 0,
                'overlayDelayMs': ms,
              },
            ))['ok'] ==
            true,
        'Delay rejected',
      );
    }

    String expected(Map<String, String> files) {
      final keys = files.keys.toList()..sort();
      return sha256
          .convert(
            utf8.encode(jsonEncode({for (final key in keys) key: files[key]})),
          )
          .toString();
    }

    void contents(Map response, Map<String, String> files) {
      check(
        response['ok'] == true &&
            response['overlayDigest'] == expected(files) &&
            response['overlayFileCount'] == files.length,
        'Worker content mismatch: $response',
      );
    }

    Future<void> run(String name, Future<void> Function() body) async {
      final watch = Stopwatch()..start();
      await body().timeout(const Duration(seconds: 35));
      results.add({
        'name': name,
        'passed': true,
        'durationMs': watch.elapsedMilliseconds,
      });
      print('PASS $name');
    }

    Future<void> replayStarted(int before) => poll(
      () async => (await admin.send('status'))['overlayReplays'] > before,
    );
    await run(
      'worker confirms applied content and unchanged requests skip replay',
      () async {
        check(
          (await update(client, 'lib/a.dart', 1, 'unsaved 中文'))['ok'] == true,
          'Update rejected',
        );
        contents(await work(client), {'lib/a.dart': 'unsaved 中文'});
        final before = (await admin.send('status'))['overlayReplays'];
        final concurrent = await Future.wait([
          for (var i = 0; i < 5; i++) work(client),
        ]);
        for (final response in concurrent) {
          contents(response, {'lib/a.dart': 'unsaved 中文'});
        }
        check(
          (await admin.send('status'))['overlayReplays'] == before,
          'Unchanged overlays replayed',
        );
      },
    );
    await run(
      'stale versions foreign owners and invalid logical paths are rejected',
      () async {
        check(
          (await update(client, 'lib/a.dart', 1, 'stale'))['ok'] == false,
          'Version reused',
        );
        check(
          (await update(admin, 'LIB/A.dart', 2, 'foreign'))['ok'] == false,
          'Owner bypassed',
        );
        for (final path in [
          '../a.dart',
          '/a.dart',
          'lib//a.dart',
          'C:/a.dart',
        ]) {
          check(
            (await update(client, path, 2, 'invalid'))['ok'] == false,
            'Invalid key accepted',
          );
        }
        contents(await work(client), {'lib/a.dart': 'unsaved 中文'});
      },
    );
    await run(
      'switching worktrees replays retained content into fresh worker',
      () async {
        final first = await work(client);
        contents(await work(admin, root: 1), {});
        final returned = await work(client);
        contents(returned, {'lib/a.dart': 'unsaved 中文'});
        check(
          returned['workerGeneration'] != first['workerGeneration'],
          'Old worker reused after root switch',
        );
      },
    );
    await run(
      'configuration replacement replays overlays without persisting them to disk',
      () async {
        final first = await work(client);
        await File(
          '${roots[0].path}/analysis_options.yaml',
        ).writeAsString('analyzer:\n  errors:\n    unused_import: ignore\n');
        final next = await work(client);
        contents(next, {'lib/a.dart': 'unsaved 中文'});
        check(
          next['workerGeneration'] != first['workerGeneration'] &&
              !File('${roots[0].path}/lib/a.dart').existsSync(),
          'No environment replacement or wrote overlay to disk',
        );
      },
    );
    await run(
      'edit while awaiting ack rejects stale result and next replay applies latest content',
      () async {
        await delay(800);
        await update(client, 'lib/a.dart', 2, 'intermediate');
        final before = (await admin.send('status'))['overlayReplays'] as int;
        final pending = work(client);
        await replayStarted(before);
        await update(client, 'lib/a.dart', 3, 'latest');
        final next = work(client);
        check((await pending)['ok'] == false, 'Stale ack succeeded');
        contents(await next, {'lib/a.dart': 'latest'});
        await delay(0);
      },
    );
    await run(
      'clear during unacknowledged replay removes content and preserves version tombstone',
      () async {
        await delay(600);
        await update(client, 'lib/a.dart', 4, 'to clear');
        final before = (await admin.send('status'))['overlayReplays'] as int;
        final pending = work(client);
        await replayStarted(before);
        await update(client, 'lib/a.dart', 5, null);
        check((await pending)['ok'] == false, 'Cleared replay succeeded');
        contents(await work(client), {});
        check(
          (await update(client, 'lib/a.dart', 4, 'resurrect'))['ok'] == false,
          'Cleared version resurrected',
        );
        await delay(0);
      },
    );
    await run(
      'cancel during replay finishes once and releases lease after acknowledgement drains',
      () async {
        await delay(600);
        await update(client, 'lib/a.dart', 6, 'cancelled request content');
        final before = (await admin.send('status'))['overlayReplays'] as int;
        final pending = work(client);
        final id = '${client.sequence}';
        await replayStarted(before);
        check(
          (await client.send('cancel', fields: {'target': id}))['found'] ==
              true,
          'Cancel missing',
        );
        check(
          (await pending)['ok'] == false && client.counts[id] == 1,
          'Cancelled result or duplicate',
        );
        await poll(() async => (await admin.send('status'))['leases'] == 0);
        contents(await work(client), {
          'lib/a.dart': 'cancelled request content',
        });
        await delay(0);
      },
    );
    await run(
      'deadline during replay rejects result and permits later request',
      () async {
        await delay(600);
        await update(client, 'lib/a.dart', 7, 'deadline');
        check(
          (await work(client, timeout: 150))['ok'] == false,
          'Replay deadline ignored',
        );
        contents(await work(client), {'lib/a.dart': 'deadline'});
        await delay(0);
      },
    );
    await run('edit after ack invalidates active synthetic result', () async {
      final pending = work(client, duration: 700);
      await poll(() async => (await admin.send('status'))['leases'] == 1);
      await update(client, 'lib/a.dart', 8, 'active edit');
      check((await pending)['ok'] == false, 'Active stale result published');
      contents(await work(client), {'lib/a.dart': 'active edit'});
    });
    await run(
      'disconnect during replay clears all owned content and next connection sees removals',
      () async {
        await delay(600);
        await update(client, 'lib/a.dart', 9, 'disconnect');
        final before = (await admin.send('status'))['overlayReplays'] as int;
        final observed = work(
          client,
        ).then<void>((_) {}, onError: (Object _) {});
        await replayStarted(before);
        client.close();
        await observed;
        await poll(
          () async => (await admin.send('status'))['outstanding'] == 0,
        );
        contents(await work(admin), {});
        check(
          (await admin.send('status'))['overlayBytes'] == 0,
          'Disconnected content retained',
        );
        await delay(0);
      },
    );
    await run(
      'worker crash during replay fails work and replacement receives retained content',
      () async {
        await update(admin, 'x.dart', 1, 'survive crash');
        await delay(1200);
        final before = (await admin.send('status'))['overlayReplays'] as int;
        final pending = work(admin);
        await replayStarted(before);
        final status = await admin.send('status');
        Process.killPid((status['pids'] as List).single['worker'] as int);
        check((await pending)['ok'] == false, 'Crash result succeeded');
        await delay(0);
        contents(await work(admin), {'x.dart': 'survive crash'});
      },
    );
    await run(
      'aggregate overlay capacity rejects excess content and clear releases budget',
      () async {
        final chunk = List.filled(40000, 'x').join();
        for (var i = 0; i < 6; i++) {
          check(
            (await update(admin, 'chunk$i.dart', 1, chunk))['ok'] == true,
            'Capacity rejected early',
          );
        }
        check(
          (await update(admin, 'excess.dart', 1, chunk))['ok'] == false,
          'Content budget exceeded',
        );
        check(
          (await admin.send('status'))['overlayBytes'] == 240013,
          'Rejected update changed budget',
        );
        for (var i = 0; i < 6; i++) {
          check(
            (await update(admin, 'chunk$i.dart', 2, null))['ok'] == true,
            'Clear rejected',
          );
        }
        contents(await work(admin), {'x.dart': 'survive crash'});
        check(
          (await admin.send('status'))['overlayBytes'] == 13,
          'Clear failed to release budget',
        );
      },
    );
    // Leave an authenticated idle connection open: shutdown must cancel its
    // timer directly rather than depend on a local socket onDone notification.
    await (await connect()).send('hello');
    await admin.send('shutdown');
    check(
      await process.exitCode.timeout(const Duration(seconds: 25)) == 0,
      'Manager cleanup failed',
    );
    final report = {
      'results': results,
      'fixture': fixture.path,
      'allPassed': true,
      'syntheticWorkerOnly': true,
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
