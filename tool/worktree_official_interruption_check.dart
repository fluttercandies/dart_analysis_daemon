// Real analyzer, deterministic response consumption gate, real memory policy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_manager_probe_check.dart' show Client, check, poll;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp(
    'dana-official-interruption-',
  );
  final root = await Directory('${fixture.path}/root').create();
  final target = File('${root.path}/probe.dart');
  await target.writeAsString('int value = missingBranch;\n');
  final manager = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--official-worker',
    '--system-memory',
    '--official-fault-gates',
  ]);
  final ready = Completer<Map>();
  manager.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (!ready.isCompleted) ready.complete(jsonDecode(line) as Map);
    },
  );
  final stderrLog = manager.stderr.transform(utf8.decoder).join();
  final clients = <Client>[];
  final results = <Map>[];
  final snapshots = <Map>[];
  final evidence = <Map>[];
  final hold = File('${fixture.path}/official-query.hold');
  final reached = File('${fixture.path}/official-query.reached');
  Client? admin;
  Map? metadata;
  var skipped = false;
  var shutdownConfirmed = false;
  Object? failure;
  Future<void> run(String name, Future<void> Function() action) async {
    final watch = Stopwatch()..start();
    await action();
    results.add({
      'name': name,
      'passed': true,
      'elapsedMs': watch.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  Future<Client> connect() async {
    final peer = await Client.connect(metadata!);
    clients.add(peer);
    return peer;
  }

  Future<Map> query(Client peer, {int timeoutMs = 20000}) => peer.send(
    'builtin-errors',
    fields: {
      'root': root.path,
      'file': target.absolute.path,
      'timeoutMs': timeoutMs,
    },
  );
  Future<Map> status() async {
    final value = await admin!.send('status');
    snapshots.add(value);
    return value;
  }

  List<Map> protocol(File log) =>
      log.readAsLinesSync().map((line) => jsonDecode(line) as Map).toList();
  void valid(Map value, {bool clean = false}) {
    check(
      value['ok'] == true &&
          value['targetPinned'] == true &&
          value['builtinOnly'] == true &&
          value['diagnosticComplete'] == false,
      'Bad official reply: $value',
    );
    final errors = value['errors'] as List;
    check(
      clean
          ? errors.isEmpty
          : errors.any((e) => '${e['message']}'.contains('missingBranch')),
      'Wrong target diagnostics',
    );
  }

  try {
    check(
      (await ready.future.timeout(const Duration(seconds: 15)))['event'] ==
          'ready',
      'Manager not ready',
    );
    metadata =
        jsonDecode(await File('${fixture.path}/manager.json').readAsString())
            as Map;
    admin = await connect();
    if ((await status())['memory']['allowed'] != true) {
      skipped = true;
      print('SKIP real memory admission');
      return;
    }
    valid(await query(admin));
    for (final mode in ['cancel', 'disconnect', 'deadline', 'target-edit']) {
      await run(
        'active $mode discards late result and drains cleanup before next query',
        () async {
          await target.writeAsString('int value = missingBranch;\n');
          if (reached.existsSync()) await reached.delete();
          await hold.writeAsString('hold', flush: true);
          final peer = await connect();
          final active = query(
            peer,
            timeoutMs: mode == 'deadline' ? 1500 : 20000,
          ).then<Map>(
            (value) => value,
            onError: (Object error) => {'disconnected': '$error'},
          );
          final requestId = '${peer.sequence}';
          await poll(() async => reached.existsSync());
          final gate = jsonDecode(await reached.readAsString()) as Map;
          final log = File(gate['protocolLog'] as String);
          final events = protocol(log);
          final gateIndex = events.lastIndexWhere(
            (e) => e['faultGate'] == 'held' && e['id'] == gate['id'],
          );
          check(
            gateIndex >= 0 &&
                events.any(
                  (e) =>
                      e['send'] == 'analysis.getErrors' &&
                      e['id'] == gate['id'],
                ),
            'Real query not written',
          );
          check(
            !events.any(
              (e) => e['receive'] is Map && e['receive']['id'] == gate['id'],
            ),
            'Response consumed before gate',
          );
          if (mode == 'cancel') {
            check(
              (await peer.send(
                    'cancel',
                    fields: {'target': requestId},
                  ))['found'] ==
                  true,
              'Cancel not found',
            );
          } else if (mode == 'disconnect') {
            peer.close();
          } else if (mode == 'deadline') {
            await Future<void>.delayed(const Duration(milliseconds: 1600));
          } else {
            await target.writeAsString('int value = 123;\n');
          }
          final followerPeer = await connect();
          var followerDone = false;
          final follower = query(followerPeer).then((value) {
            followerDone = true;
            return value;
          });
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final held = await status();
          check(
            !followerDone &&
                held['leases'] >= 1 &&
                held['starts'] == 1 &&
                held['degraded'] == null,
            'Lease released or duplicate tree before drain',
          );
          check(
            !protocol(log)
                .skip(gateIndex + 1)
                .any(
                  (e) =>
                      e['diskQuery'] == 'cleanupAck' ||
                      e['diskQuery'] == 'begin',
                ),
            'Queue crossed held query',
          );
          final releaseWatch = Stopwatch()..start();
          await hold.delete();
          final original = await active;
          valid(await follower, clean: mode == 'target-edit');
          if (mode == 'disconnect') {
            check(
              original.containsKey('disconnected'),
              'Disconnected request returned success',
            );
          } else {
            check(
              original['ok'] == false && peer.counts[requestId] == 1,
              'Interrupted request success or duplicate terminal response',
            );
            if (mode == 'target-edit') {
              check(
                '${original['error']}'.contains('Target changed'),
                'Missing change failure',
              );
            }
          }
          final after = protocol(log);
          final cleanup = after.indexWhere(
            (e) => e['diskQuery'] == 'cleanupAck',
            gateIndex + 1,
          );
          final next = after.indexWhere(
            (e) => e['diskQuery'] == 'begin',
            gateIndex + 1,
          );
          final response = after.indexWhere(
            (e) => e['receive'] is Map && e['receive']['id'] == gate['id'],
            gateIndex + 1,
          );
          check(
            response > gateIndex && cleanup > response && next > cleanup,
            'Late response/cleanup/next query order broken',
          );
          evidence.add({
            'mode': mode,
            'protocolLog': log.path,
            'queryId': gate['id'],
            'heldIndex': gateIndex,
            'responseIndex': response,
            'cleanupIndex': cleanup,
            'nextQueryIndex': next,
            'releaseToDrainAndNextMs': releaseWatch.elapsedMilliseconds,
            'original': original,
          });
          await poll(() async => (await status())['leases'] == 0);
        },
      );
    }
    for (final mode in ['queued-cancel', 'queued-deadline']) {
      await run(
        '$mode skips transport while previous real query remains held',
        () async {
          await target.writeAsString('int value = missingBranch;\n');
          if (reached.existsSync()) await reached.delete();
          await hold.writeAsString('hold', flush: true);
          final activePeer = await connect();
          final active = query(activePeer);
          await poll(() async => reached.existsSync());
          final gate = jsonDecode(await reached.readAsString()) as Map;
          final log = File(gate['protocolLog'] as String);
          final queuedPeer = await connect();
          final queued = query(
            queuedPeer,
            timeoutMs: mode == 'queued-deadline' ? 600 : 20000,
          );
          final requestId = '${queuedPeer.sequence}';
          await poll(() async => (await status())['leases'] == 2);
          final terminalWatch = Stopwatch()..start();
          if (mode == 'queued-cancel') {
            check(
              (await queuedPeer.send(
                    'cancel',
                    fields: {'target': requestId},
                  ))['found'] ==
                  true,
              'Queued cancel missed',
            );
          }
          final rejected = await queued;
          check(
            rejected['ok'] == false &&
                queuedPeer.counts[requestId] == 1 &&
                hold.existsSync(),
            'Queued work did not finish before release',
          );
          check((await status())['leases'] == 1, 'Queued lease retained');
          final held = protocol(log);
          final gateIndex = held.lastIndexWhere(
            (e) => e['faultGate'] == 'held' && e['id'] == gate['id'],
          );
          check(
            !held.skip(gateIndex + 1).any((e) => e['diskQuery'] == 'begin'),
            'Canceled queued query entered transport',
          );
          final completedMs = terminalWatch.elapsedMilliseconds;
          await hold.delete();
          valid(await active);
          valid(await query(admin!));
          evidence.add({
            'mode': mode,
            'queuedTerminalMs': completedMs,
            'original': rejected,
            'protocolLog': log.path,
            'queryId': gate['id'],
          });
        },
      );
    }
    await run(
      'unreleased response gate poisons worker and replacement follows Job zero',
      () async {
        await target.writeAsString('int value = missingBranch;\n');
        if (reached.existsSync()) await reached.delete();
        await hold.writeAsString('hold', flush: true);
        final peer = await connect();
        final active = query(peer);
        await poll(() async => reached.existsSync());
        check((await active)['ok'] == false, 'Gate timeout returned success');
        await hold.delete();
        await poll(() async => (await status())['trackedWorkers'] == 0);
        valid(await query(admin!));
        final recovered = await status();
        check(
          recovered['starts'] == 2 &&
              recovered['trackedWorkers'] == 1 &&
              recovered['degraded'] == null,
          'Replacement failed or overlapped unconfirmed tree',
        );
      },
    );
    await run(
      'shutdown confirms all remaining jobs empty and removes endpoint',
      () async {
        check(
          (await admin!.send('shutdown'))['ok'] == true,
          'Shutdown rejected',
        );
        check(
          await manager.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Shutdown cleanup failed',
        );
        shutdownConfirmed = true;
        check(
          !File('${fixture.path}/manager.json').existsSync(),
          'Endpoint retained',
        );
      },
    );
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    if (hold.existsSync()) await hold.delete();
    if (!shutdownConfirmed) {
      try {
        await admin?.send('shutdown');
        check(
          await manager.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Final cleanup failed',
        );
        shutdownConfirmed = true;
      } catch (error) {
        failure ??= error;
        manager.kill();
      }
    }
    for (final peer in clients) {
      peer.close();
    }
    final report = {
      'fixture': fixture.path,
      'skipped': skipped,
      'allPassed':
          !skipped &&
          failure == null &&
          results.length == 8 &&
          shutdownConfirmed,
      'failure': failure?.toString(),
      'shutdownConfirmed': shutdownConfirmed,
      'responseConsumptionGate': true,
      'results': results,
      'evidence': evidence,
      'snapshots': snapshots,
      'managerStderr': await stderrLog.timeout(const Duration(seconds: 5)),
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
