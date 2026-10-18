// Real analyzer integration, opt-in only; never starts multiple trees at once.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_manager_probe_check.dart' show Client, check, poll;
import 'worktree_test_runtime.dart';

Future<void> main() async {
  final alternateDart = requireTestRuntime('DANA_TEST_ALTERNATE_DART');
  final alternateVersion = await testRuntimeVersion(alternateDart);
  final fixture = await Directory.systemTemp.createTemp(
    'dana-official-manager-',
  );
  final roots = <Directory>[];
  for (var i = 0; i < 3; i++) {
    final root = await Directory('${fixture.path}/root$i').create();
    roots.add(root);
    await File(
      '${root.path}/probe.dart',
    ).writeAsString('int value = missingBranch$i;\n');
    await File(
      '${root.path}/pubspec.yaml',
    ).writeAsString('name: manager_probe_$i\nenvironment:\n  sdk: ^3.9.0\n');
  }
  final script =
      File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path;
  final results = <Map>[];
  final snapshots = <Map>[];
  final clients = <Client>[];
  Process? manager;
  Client? admin;
  Timer? sampler;
  var sampling = false;
  var skipped = false;
  Object? failure;
  var shutdownConfirmed = false;
  Future<void> run(String name, Future<void> Function() body) async {
    final watch = Stopwatch()..start();
    await body();
    results.add({
      'name': name,
      'passed': true,
      'elapsedMs': watch.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  try {
    await run(
      'official mode refuses missing real sampler and synthetic overlays',
      () async {
        for (final flags in [
          ['--official-worker'],
          ['--official-worker', '--system-memory', '--overlays'],
        ]) {
          final child = await Process.start(Platform.resolvedExecutable, [
            script,
            fixture.path,
            ...flags,
          ]);
          unawaited(child.stdout.drain<void>());
          unawaited(child.stderr.drain<void>());
          check(
            await child.exitCode.timeout(const Duration(seconds: 10)) != 0,
            'Unsafe official mode accepted',
          );
        }
      },
    );
    final child =
        manager = await Process.start(Platform.resolvedExecutable, [
          script,
          fixture.path,
          '--official-worker',
          '--system-memory',
        ]);
    final ready = Completer<Map>();
    child.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (!ready.isCompleted) ready.complete(jsonDecode(line) as Map);
      },
    );
    child.stderr.transform(utf8.decoder).listen(stderr.write);
    check(
      (await ready.future.timeout(const Duration(seconds: 15)))['event'] ==
          'ready',
      'Manager not ready',
    );
    final endpoint = File('${fixture.path}/manager.json');
    final metadata = jsonDecode(await endpoint.readAsString()) as Map;
    final control = admin = await Client.connect(metadata);
    clients.add(control);
    final initial = await control.send('status');
    snapshots.add(initial);
    check(initial['officialWorker'] == true, 'Wrong mode');
    if (initial['memory']['allowed'] != true) {
      skipped = true;
      print('SKIP real analyzer admission ${jsonEncode(initial['memory'])}');
      return;
    }
    sampler = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (sampling || snapshots.length >= 1024) return;
      sampling = true;
      try {
        snapshots.add(await control.send('status'));
      } catch (_) {
      } finally {
        sampling = false;
      }
    });
    Future<Map> query(Client client, int branch, {String? runtime}) =>
        client.send(
          'builtin-errors',
          fields: {
            'root': roots[branch].path,
            'file': File('${roots[branch].path}/probe.dart').absolute.path,
            'timeoutMs': 20000,
            if (runtime != null) 'dartExecutable': runtime,
          },
        );
    void validate(Map result, int branch) {
      check(
        result['ok'] == true &&
            result['synthetic'] == false &&
            result['builtinOnly'] == true &&
            result['diagnosticComplete'] == false &&
            (result['errors'] as List).any(
              (e) => '${e['message']}'.contains('missingBranch$branch'),
            ),
        'Wrong official result: $result',
      );
    }

    await run(
      'cancel during cold startup discards result and reclaims the unused tree',
      () async {
        final peer = await Client.connect(metadata);
        clients.add(peer);
        final work = query(peer, 0);
        final target = '${peer.sequence}';
        await poll(
          () async => (await control.send('status'))['nativeAttempts'] == 1,
        );
        check(
          (await peer.send('cancel', fields: {'target': target}))['found'] ==
              true,
          'Cold request already lost',
        );
        check(
          (await work)['ok'] == false,
          'Canceled initialization returned success',
        );
        await poll(() async {
          final status = await control.send('status');
          return status['slots'] == 0 && status['trackedWorkers'] == 0;
        });
      },
    );
    await run(
      'five clients share one official worker and return real built-in errors',
      () async {
        final peers = await Future.wait([
          for (var i = 0; i < 5; i++) Client.connect(metadata),
        ]);
        clients.addAll(peers);
        final replies = await Future.wait([
          for (final peer in peers) query(peer, 0),
        ]);
        for (final reply in replies) {
          validate(reply, 0);
        }
        check(
          replies.map((r) => r['workerGeneration']).toSet().length == 1,
          'Duplicate generations',
        );
        final status = await control.send('status');
        snapshots.add(status);
        check(
          status['starts'] == 2 && status['trackedWorkers'] == 1,
          'Duplicate trees',
        );
        results.add({
          'timings':
              replies
                  .map(
                    (r) => {
                      'initializationMs': r['initializationMs'],
                      'analysisMs': r['analysisMs'],
                    },
                  )
                  .toList(),
        });
      },
    );
    await run('official mode rejects injection and unsaved content', () async {
      check(
        (await control.send(
              'observe-overlay',
              fields: {
                'root': roots[0].path,
                'file': '${roots[0].path}/probe.dart',
                'timeoutMs': 20000,
                'overlays': {},
                'expectedCodes': [],
              },
            ))['ok'] ==
            false,
        'Request overlays accepted without explicit opt-in',
      );
      check(
        (await control.send('memory', fields: {'allowed': true}))['ok'] ==
            false,
        'Real sampling overridden',
      );
      check(
        (await control.send(
              'builtin-errors',
              fields: {
                'root': roots[0].path,
                'file': '${roots[0].path}/probe.dart',
                'timeoutMs': 20000,
                'content': 'int value = 0;',
              },
            ))['ok'] ==
            false,
        'Unsaved content ignored',
      );
      check(
        (await control.send(
              'check',
              fields: {'root': roots[0].path, 'timeoutMs': 20000, 'workMs': 0},
            ))['ok'] ==
            false,
        'Synthetic operation accepted',
      );
    });
    await run(
      'saved edits avoid stale watcher diagnostics and retain target digest',
      () async {
        final file = File('${roots[0].path}/probe.dart');
        await file.writeAsString('int value = 42;\n');
        final clean = await query(control, 0);
        check(
          clean['ok'] == true &&
              clean['targetPinned'] == true &&
              (clean['errors'] as List).isEmpty,
          'Watcher returned stale errors',
        );
        await file.writeAsString('int value = missingBranch0;\n');
        final restored = await query(control, 0);
        validate(restored, 0);
        check(
          restored['targetDigest'] != clean['targetDigest'],
          'Target revision unchanged',
        );
      },
    );
    await run(
      'queued disk edit rejects stale result while cross-root Jobs remain sequential',
      () async {
        final work = Future.wait([query(clients[1], 1), query(clients[2], 2)]);
        await poll(
          () async => (await control.send('status'))['nativeAttempts'] >= 3,
        );
        await File(
          '${roots[1].path}/probe.dart',
        ).writeAsString('int value = 123;\n');
        final replies = await work;
        check(
          replies[0]['ok'] == false &&
              '${replies[0]['error']}'.contains('Target changed'),
          'Queued target edit returned stale success',
        );
        validate(replies[1], 2);
        final status = await control.send('status');
        snapshots.add(status);
        check(
          status['starts'] == 4 &&
              status['trackedWorkers'] == 1 &&
              status['degraded'] == null,
          'Switch did not reclaim',
        );
      },
    );
    await run(
      'SDK selection replaces worker and returns actual selected runtime',
      () async {
        final runtime = alternateDart;
        check(File(runtime).existsSync(), 'Expected SDK unavailable');
        final result = await query(control, 2, runtime: runtime);
        validate(result, 2);
        check(
          '${result['workerRuntimeVersion']}'.startsWith(alternateVersion) &&
              '${result['runtimeVersion']}'.contains(alternateVersion),
          'Runtime selection ignored',
        );
        check(
          (await control.send('status'))['starts'] == 5,
          'SDK change reused old tree',
        );
      },
    );
    await run(
      'configuration change invalidates old generation and rebuilds',
      () async {
        await File(
          '${roots[2].path}/analysis_options.yaml',
        ).writeAsString('analyzer:\n  errors:\n    unused_import: ignore\n');
        final result = await query(control, 2, runtime: alternateDart);
        validate(result, 2);
        check(
          (await control.send('status'))['starts'] == 6,
          'Environment change reused old tree',
        );
      },
    );
    await run(
      'owned worker crash reclaims descendants before next real query',
      () async {
        final before = await control.send('status');
        final workerPid = before['pids'][0]['worker'] as int;
        check(
          workerPid > 0 && workerPid != pid && workerPid != child.pid,
          'Invalid owned PID',
        );
        check(Process.killPid(workerPid), 'Crash injection failed');
        await poll(
          () async => (await control.send('status'))['trackedWorkers'] == 0,
        );
        validate(await query(control, 2, runtime: alternateDart), 2);
        check((await control.send('status'))['starts'] == 7, 'No replacement');
      },
    );
    sampler.cancel();
    await run(
      'shutdown drains real jobs and removes global endpoint',
      () async {
        check(
          (await control.send('shutdown'))['ok'] == true,
          'Shutdown rejected',
        );
        check(
          await child.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Manager cleanup failed',
        );
        check(!endpoint.existsSync(), 'Endpoint survived');
        shutdownConfirmed = true;
      },
    );
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    sampler?.cancel();
    if (manager != null && !shutdownConfirmed) {
      try {
        await admin?.send('shutdown');
        check(
          await manager.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Cleanup failed',
        );
        shutdownConfirmed = true;
      } catch (error) {
        failure ??= error;
        // Closing the manager lets the native owner observe its parent exit.
        manager.kill();
      }
    }
    for (final client in clients) {
      client.close();
    }
    final report = {
      'fixture': fixture.path,
      'skipped': skipped,
      'results': results,
      'failure': failure?.toString(),
      'shutdownConfirmed': shutdownConfirmed,
      'allPassed': !skipped && failure == null && shutdownConfirmed,
      'snapshots': snapshots,
    };
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(
      jsonEncode({
        'fixture': fixture.path,
        'allPassed': report['allPassed'],
        'failure': report['failure'],
      }),
    );
    if (failure != null) exitCode = 1;
  }
}
