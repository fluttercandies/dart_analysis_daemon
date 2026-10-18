import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Client {
  Client(this.socket, this.metadata) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final message = jsonDecode(line) as Map;
            final id = message['id'] as String?;
            if (id != null) {
              counts.update(id, (value) => value + 1, ifAbsent: () => 1);
              pending.remove(id)?.complete(message);
            }
          },
          onDone: () {
            disconnected = true;
            for (final request in pending.values) {
              request.completeError(StateError('Disconnected'));
            }
            pending.clear();
          },
        );
  }
  final Socket socket;
  final Map metadata;
  final pending = <String, Completer<Map>>{};
  final counts = <String, int>{};
  int sequence = 0;
  bool disconnected = false;
  Future<Map> send(
    String op, {
    Map<String, Object?> fields = const {},
    Map<String, Object?> auth = const {},
    Duration responseTimeout = const Duration(seconds: 25),
  }) {
    if (disconnected) return Future.error(StateError('Disconnected'));
    final id = '${++sequence}';
    final result = pending[id] = Completer<Map>();
    socket.writeln(
      jsonEncode({
        'protocol': 1,
        'token': metadata['token'],
        'generation': metadata['generation'],
        'id': id,
        'op': op,
        ...fields,
        ...auth,
      }),
    );
    return result.future.timeout(responseTimeout);
  }

  static Future<Client> connect(Map metadata) async => Client(
    await Socket.connect(
      metadata['address'] as String,
      metadata['port'] as int,
    ),
    metadata,
  );
  void close() {
    disconnected = true;
    socket.destroy();
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> poll(Future<bool> Function() predicate) async {
  final timer = Stopwatch()..start();
  while (!await predicate()) {
    if (timer.elapsed > const Duration(seconds: 25)) {
      throw TimeoutException('Polling state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-manager-probe-');
  final roots = [
    for (var i = 0; i < 3; i++)
      await Directory('${fixture.path}/root$i').create(),
  ];
  final endpoint = File('${fixture.path}/manager.json');
  final processes = <Process>[];
  final clients = <Client>[];
  final results = <Map>[];
  final firstEvents = <Process, Completer<Map>>{};
  Future<Process> start({bool systemMemory = false}) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
      fixture.path,
      if (systemMemory) '--system-memory',
    ]);
    processes.add(process);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final first = firstEvents[process] = Completer<Map>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!first.isCompleted) first.complete(jsonDecode(line) as Map);
        });
    return process;
  }

  Future<Map> readyEvent(Process process) =>
      firstEvents[process]!.future.timeout(const Duration(seconds: 15));

  Future<void> run(String name, Future<void> Function() body) async {
    final timer = Stopwatch()..start();
    await body();
    results.add({
      'name': name,
      'passed': true,
      'durationMs': timer.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  final owner = await start();
  try {
    final ready = await readyEvent(owner);
    check(ready['event'] == 'ready', 'Manager did not start');
    final metadata = jsonDecode(await endpoint.readAsString()) as Map;
    final client = await Client.connect(metadata);
    clients.add(client);
    final admin = await Client.connect(metadata);
    clients.add(admin);
    await run('lifetime startup lock blocks a competing process', () async {
      final competing = await start();
      final event = await readyEvent(competing);
      check(
        await competing.exitCode == 0 && event['event'] == 'already-running',
        'Competing manager acquired lock',
      );
      check(
        (jsonDecode(await endpoint.readAsString()) as Map)['generation'] ==
            metadata['generation'],
        'Endpoint replaced',
      );
    });
    await run(
      'handshake rejects token protocol and generation mismatches',
      () async {
        for (final auth in [
          {'token': 'wrong'},
          {'protocol': 0},
          {'generation': 'old'},
        ]) {
          check(
            (await client.send('hello', auth: auth))['ok'] == false,
            'Invalid auth accepted',
          );
        }
        check(
          (await client.send('hello'))['ok'] == true,
          'Valid auth rejected',
        );
      },
    );
    await run(
      'injected admission denies startup, deadline and cancellation finish once',
      () async {
        await admin.send('memory', fields: {'allowed': false});
        final expired = client.send(
          'check',
          fields: {'root': roots[0].path, 'workMs': 1, 'timeoutMs': 120},
        );
        check((await expired)['ok'] == false, 'Admission deadline succeeded');
        final cancelled = client.send(
          'check',
          fields: {'root': roots[0].path, 'workMs': 1, 'timeoutMs': 10000},
        );
        final requestId = '${client.sequence}';
        await poll(() async => (await admin.send('status'))['queued'] == 1);
        await client.send('cancel', fields: {'target': requestId});
        check(
          (await cancelled)['ok'] == false && client.counts[requestId] == 1,
          'Cancellation termination incorrect',
        );
        check(
          (await admin.send('status'))['starts'] == 0,
          'Denied admission launched worker',
        );
        await admin.send('memory', fields: {'allowed': true});
      },
    );
    await run('ten same-root requests share one native Job worker', () async {
      final responses = await Future.wait([
        for (var i = 0; i < 10; i++)
          client.send(
            'check',
            fields: {'root': roots[0].path, 'workMs': 30, 'timeoutMs': 15000},
          ),
      ]);
      check(
        responses.every((r) => r['ok'] == true) &&
            responses.map((r) => r['workerGeneration']).toSet().length == 1,
        'Root deduplication failed',
      );
      check((await admin.send('status'))['starts'] == 1, 'Duplicate workers');
    });
    await run(
      'path aliases reuse one resident worker and invalid roots never start one',
      () async {
        final child = await Directory('${roots[0].path}/nested').create();
        final alias = '${fixture.path}/root-alias';
        final shell =
            '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        final setup = await Process.run(
          shell,
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'$ErrorActionPreference="Stop"; $null=New-Item -ItemType Junction -Path $env:DANA_ID_ALIAS -Target $env:DANA_ID_ROOT',
          ],
          environment: {'DANA_ID_ALIAS': alias, 'DANA_ID_ROOT': roots[0].path},
        );
        check(setup.exitCode == 0, 'Could not prepare dedicated junction');
        final responses = await Future.wait([
          for (final path in [
            roots[0].path.toUpperCase(),
            '${child.path}/..',
            roots[0].path.replaceAll('\\', '/'),
            alias,
          ])
            client.send(
              'check',
              fields: {'root': path, 'workMs': 10, 'timeoutMs': 15000},
            ),
        ]);
        check(
          responses.every((r) => r['ok'] == true) &&
              responses.map((r) => r['workerGeneration']).toSet().length == 1,
          'Aliases did not share worker generation',
        );
        final file = await File(
          '${fixture.path}/not-a-root',
        ).writeAsString('fixture');
        for (final invalid in [
          'relative',
          file.path,
          '${fixture.path}/absent',
        ]) {
          check(
            (await client.send(
                  'check',
                  fields: {'root': invalid, 'workMs': 1, 'timeoutMs': 100},
                ))['ok'] ==
                false,
            'Invalid root accepted',
          );
        }
        check(
          (await admin.send('status'))['starts'] == 1,
          'Alias or invalid path created extra worker',
        );
      },
    );
    await run(
      'three roots queue and reclaim previous Job before replacement',
      () async {
        final responses = await Future.wait([
          for (final root in roots)
            client.send(
              'check',
              fields: {'root': root.path, 'workMs': 20, 'timeoutMs': 20000},
            ),
        ]);
        check(
          responses.every((r) => r['ok'] == true),
          'Cross-root request failed',
        );
        final state = await admin.send('status');
        check(
          state['slots'] == 1 &&
              state['starts'] == 3 &&
              state['trackedWorkers'] == 1,
          'Worker slot count wrong',
        );
      },
    );
    await run('active request cancellation releases its lease', () async {
      final result = client.send(
        'check',
        fields: {'root': roots[2].path, 'workMs': 10000, 'timeoutMs': 15000},
      );
      final requestId = '${client.sequence}';
      await poll(() async => (await admin.send('status'))['leases'] == 1);
      await client.send('cancel', fields: {'target': requestId});
      check(
        (await result)['ok'] == false && client.counts[requestId] == 1,
        'Active cancellation incorrect',
      );
      await poll(() async => (await admin.send('status'))['leases'] == 0);
    });
    await run(
      'disconnect releases active lease and cancels queued request',
      () async {
        final transient = await Client.connect(metadata);
        clients.add(transient);
        final work = transient
            .send(
              'check',
              fields: {
                'root': roots[2].path,
                'workMs': 10000,
                'timeoutMs': 15000,
              },
            )
            .then((_) {}, onError: (Object _) {});
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        final queued = transient
            .send(
              'check',
              fields: {'root': roots[0].path, 'workMs': 1, 'timeoutMs': 15000},
            )
            .then((_) {}, onError: (Object _) {});
        await poll(() async => (await admin.send('status'))['queued'] == 1);
        transient.close();
        await Future.wait([work, queued]);
        await poll(() async {
          final state = await admin.send('status');
          return state['leases'] == 0 && state['queued'] == 0;
        });
      },
    );
    await run(
      'worker-only crash fails active work and clears surviving descendants before replacement',
      () async {
        final work = client.send(
          'check',
          fields: {'root': roots[2].path, 'workMs': 10000, 'timeoutMs': 15000},
        );
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        await poll(() async {
          final pids = (await admin.send('status'))['pids'] as List;
          return pids.isNotEmpty && (pids.last as Map)['healthFresh'] == true;
        });
        final owned =
            ((await admin.send('status'))['pids'] as List).last as Map;
        check(
          (owned['peakPrivateCommitMiB'] as num) > 0,
          'Job peak commit missing',
        );
        final replacement = client.send(
          'check',
          fields: {'root': roots[1].path, 'workMs': 1, 'timeoutMs': 15000},
        );
        final crashClock = Stopwatch()..start();
        check(
          Process.killPid(owned['worker'] as int),
          'Failed to kill dedicated worker',
        );
        check((await work)['ok'] == false, 'Crashed worker returned success');
        check(
          crashClock.elapsedMilliseconds < 2000,
          'Crash failed to interrupt active work promptly',
        );
        check(
          (await replacement)['ok'] == true,
          'Cleaned crash did not permit replacement',
        );
        check(
          (await admin.send('status'))['degraded'] == null,
          'Confirmed crash cleanup degraded manager',
        );
      },
    );
    await run(
      'runtime pressure protects active lease and blocks new leases until recovery',
      () async {
        final work = client.send(
          'check',
          fields: {'root': roots[1].path, 'workMs': 10000, 'timeoutMs': 15000},
        );
        final activeId = '${client.sequence}';
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        await admin.send(
          'research-policy',
          fields: {'pressure': true, 'idleMs': 60000},
        );
        final queued = client.send(
          'check',
          fields: {'root': roots[0].path, 'workMs': 1, 'timeoutMs': 150},
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final pressured = await admin.send('status');
        check(
          pressured['leases'] == 1 && (pressured['pids'] as List).isNotEmpty,
          'Pressure killed active lease',
        );
        check(
          (await queued)['ok'] == false,
          'Pressure admitted queued request',
        );
        await client.send('cancel', fields: {'target': activeId});
        check((await work)['ok'] == false, 'Cancelled work returned success');
        await poll(() async => (await admin.send('status'))['slots'] == 0);
        await admin.send(
          'research-policy',
          fields: {'pressure': false, 'idleMs': 60000},
        );
        check(
          (await client.send(
                'check',
                fields: {
                  'root': roots[0].path,
                  'workMs': 1,
                  'timeoutMs': 15000,
                },
              ))['ok'] ==
              true,
          'Recovery failed',
        );
      },
    );
    await run(
      'idle worker reaches Job zero without another root request',
      () async {
        await admin.send(
          'research-policy',
          fields: {'pressure': false, 'idleMs': 200},
        );
        await poll(() async => (await admin.send('status'))['slots'] == 0);
        check(
          ((await admin.send('status'))['pids'] as List).isEmpty,
          'Idle Job remains',
        );
        await admin.send(
          'research-policy',
          fields: {'pressure': false, 'idleMs': 60000},
        );
      },
    );
    await run(
      'soft pressure preserves successful in-flight result before reclamation',
      () async {
        final work = client.send(
          'check',
          fields: {'root': roots[0].path, 'workMs': 500, 'timeoutMs': 15000},
        );
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        await admin.send(
          'research-policy',
          fields: {'pressure': true, 'idleMs': 60000},
        );
        check(
          (await work)['ok'] == true,
          'Soft pressure discarded a valid active result',
        );
        await poll(() async => (await admin.send('status'))['slots'] == 0);
        await admin.send(
          'research-policy',
          fields: {'pressure': false, 'idleMs': 60000},
        );
      },
    );
    for (final reason in ['peak cap', 'stale health']) {
      await run(
        '$reason stops new leases and reclaims only after active release',
        () async {
          final work = client.send(
            'check',
            fields: {
              'root': roots[0].path,
              'workMs': 10000,
              'timeoutMs': 15000,
            },
          );
          final activeId = '${client.sequence}';
          await poll(() async => (await admin.send('status'))['leases'] == 1);
          await poll(() async {
            final pids = (await admin.send('status'))['pids'] as List;
            return pids.isNotEmpty && (pids.last as Map)['healthFresh'] == true;
          });
          await admin.send(
            'research-policy',
            fields: {
              'pressure': false,
              'idleMs': 60000,
              if (reason == 'peak cap') 'peakLimitMiB': 1,
              if (reason == 'stale health') 'pauseHealth': true,
            },
          );
          await poll(
            () async => (await admin.send('status'))['runtimeAllowed'] == false,
          );
          check(
            (await admin.send('status'))['leases'] == 1,
            'Budget killed active work',
          );
          final rejected = await client.send(
            'check',
            fields: {'root': roots[0].path, 'workMs': 1, 'timeoutMs': 100},
          );
          check(
            rejected['ok'] == false,
            'Unsafe worker admitted same-root lease',
          );
          await client.send('cancel', fields: {'target': activeId});
          check((await work)['ok'] == false, 'Cancelled work succeeded');
          await poll(() async => (await admin.send('status'))['slots'] == 0);
          await admin.send(
            'research-policy',
            fields: {'pressure': false, 'idleMs': 60000, 'peakLimitMiB': 4096},
          );
        },
      );
    }
    await run(
      'shutdown removes endpoint and confirms native Job empty',
      () async {
        await admin.send('shutdown');
        check(
          await owner.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Manager cleanup failed',
        );
        check(!await endpoint.exists(), 'Endpoint not removed');
      },
    );
    await run(
      'manager crash clears owned Job and restart replaces stale endpoint',
      () async {
        final crashOwner = await start();
        check(
          (await readyEvent(crashOwner))['event'] == 'ready',
          'Crash manager readiness missing',
        );
        final oldMetadata = jsonDecode(await endpoint.readAsString()) as Map;
        final crashClient = await Client.connect(oldMetadata);
        clients.add(crashClient);
        check(
          (await crashClient.send(
                'check',
                fields: {
                  'root': roots[0].path,
                  'workMs': 1,
                  'timeoutMs': 15000,
                },
              ))['ok'] ==
              true,
          'Crash setup failed',
        );
        final state = await crashClient.send('status');
        final nativePids = (state['pids'] as List).single as Map;
        // The check controller holds exact process handles in PowerShell before
        // killing only this manager's actual VM PID (read from endpoint metadata).
        final shell =
            '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        final evidence = await Process.run(shell, [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'$ErrorActionPreference="Stop"; '
              '\$manager=Get-Process -Id ${oldMetadata['pid']}; \$owner=Get-Process -Id ${nativePids['owner']}; \$worker=Get-Process -Id ${nativePids['worker']}; \$leaf=Get-Process -Id ${nativePids['leaf']}; '
              r'$null=$manager.Handle; $null=$owner.Handle; $null=$worker.Handle; $null=$leaf.Handle; $manager.Kill(); foreach($item in @($manager,$owner,$worker,$leaf)) { if(-not $item.WaitForExit(15000)) { throw "Owned process survived manager crash" } }; "all-held-processes-exited"',
        ]);
        check(
          evidence.exitCode == 0 &&
              '${evidence.stdout}'.contains('all-held-processes-exited'),
          'Crash cleanup failed: ${evidence.stderr}',
        );
        await crashOwner.exitCode.timeout(const Duration(seconds: 10));
        check(
          await endpoint.exists(),
          'Expected stale endpoint to test recovery',
        );
        final replacement = await start();
        check(
          (await readyEvent(replacement))['event'] == 'ready',
          'Replacement readiness missing',
        );
        final newMetadata = jsonDecode(await endpoint.readAsString()) as Map;
        check(
          newMetadata['generation'] != oldMetadata['generation'],
          'Restart reused generation',
        );
        final replacementClient = await Client.connect(newMetadata);
        clients.add(replacementClient);
        check(
          (await replacementClient.send(
                'hello',
                auth: {
                  'token': oldMetadata['token'],
                  'generation': oldMetadata['generation'],
                },
              ))['ok'] ==
              false,
          'Stale credentials accepted',
        );
        check(
          (await replacementClient.send(
                'check',
                fields: {
                  'root': roots[1].path,
                  'workMs': 1,
                  'timeoutMs': 15000,
                },
              ))['ok'] ==
              true,
          'Replacement failed',
        );
        await replacementClient.send('shutdown');
        check(
          await replacement.exitCode.timeout(const Duration(seconds: 25)) ==
                  0 &&
              !await endpoint.exists(),
          'Replacement cleanup failed',
        );
      },
    );
    await run(
      'real memory admission cannot be bypassed by test injection',
      () async {
        final guarded = await start(systemMemory: true);
        check(
          (await readyEvent(guarded))['event'] == 'ready',
          'Guarded manager missing',
        );
        final metadata = jsonDecode(await endpoint.readAsString()) as Map;
        final guardedClient = await Client.connect(metadata);
        clients.add(guardedClient);
        final state = await guardedClient.send('status');
        check(
          state['memory'] is Map && state['starts'] == 0,
          'Real sampler absent',
        );
        check(
          (await guardedClient.send(
                'memory',
                fields: {'allowed': true},
              ))['ok'] ==
              false,
          'Injected admission bypassed real sampler',
        );
        final realMemory = state['memory'] as Map;
        // Low-memory paths must finish the queue deadline without creating a Job.
        if (realMemory['allowed'] == false) {
          final denied = await guardedClient.send(
            'check',
            fields: {'root': roots[0].path, 'workMs': 1, 'timeoutMs': 100},
          );
          check(denied['ok'] == false, 'Denied request succeeded');
          check(
            (await guardedClient.send('status'))['starts'] == 0,
            'Denied request created worker',
          );
        }
        print('REAL_MEMORY ${jsonEncode(realMemory)}');
        await guardedClient.send('shutdown');
        check(
          await guarded.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Guarded cleanup failed',
        );
      },
    );
    await run(
      'unexpected native owner exit invalidates active results and retains slot',
      () async {
        final manager = await start();
        check(
          (await readyEvent(manager))['event'] == 'ready',
          'Missing manager',
        );
        final metadata = jsonDecode(await endpoint.readAsString()) as Map;
        final victim = await Client.connect(metadata);
        clients.add(victim);
        final observer = await Client.connect(metadata);
        clients.add(observer);
        final work = victim.send(
          'check',
          fields: {'root': roots[0].path, 'workMs': 3000, 'timeoutMs': 15000},
        );
        await poll(() async => (await observer.send('status'))['leases'] == 1);
        final state = await observer.send('status');
        final owned = (state['pids'] as List).single as Map;
        check(
          Process.killPid(owned['owner'] as int),
          'Failed to terminate owned research owner',
        );
        await poll(
          () async => (await observer.send('status'))['degraded'] != null,
        );
        check(
          (await work)['ok'] == false,
          'Dead owner produced successful result',
        );
        final failed = await observer.send('status');
        check(
          failed['slots'] == 1 && failed['leases'] == 0,
          'Unconfirmed slot released',
        );
        check(
          (await victim.send(
                'check',
                fields: {'root': roots[1].path, 'workMs': 0, 'timeoutMs': 100},
              ))['ok'] ==
              false,
          'Degraded scheduler expanded',
        );
        await observer.send('shutdown');
        check(
          await manager.exitCode.timeout(const Duration(seconds: 10)) != 0,
          'Unconfirmed cleanup reported success',
        );
      },
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
    for (final process in processes) {
      try {
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 25));
      } on TimeoutException {
        process.kill();
      }
    }
  }
}
