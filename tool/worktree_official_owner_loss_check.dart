// Real owner-loss check: an unconfirmed Job must retain its scheduler slot.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_manager_probe_check.dart' show Client, check, poll;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp(
    'dana-official-owner-loss-',
  );
  final root = await Directory('${fixture.path}/root').create();
  await File(
    '${root.path}/probe.dart',
  ).writeAsString('int value = missingOwner;\n');
  final child = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--official-worker',
    '--system-memory',
  ]);
  final ready = Completer<Map>();
  child.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    if (!ready.isCompleted) ready.complete(jsonDecode(line) as Map);
  });
  // Nonzero manager shutdown is expected after owner loss.
  final errors = child.stderr.transform(utf8.decoder).join();
  final endpoint = File('${fixture.path}/manager.json');
  Client? client;
  var ownerLost = false;
  var passed = false;
  var skipped = false;
  Object? failure;
  final snapshots = <Map>[];
  int? managerExit;
  try {
    check(
      (await ready.future.timeout(const Duration(seconds: 15)))['event'] ==
          'ready',
      'Not ready',
    );
    final control =
        client = await Client.connect(
          jsonDecode(await endpoint.readAsString()) as Map,
        );
    final status = await control.send('status');
    snapshots.add(status);
    if (status['memory']['allowed'] != true) {
      skipped = true;
      print('SKIP owner loss admission ${jsonEncode(status['memory'])}');
      return;
    }
    final reply = await control.send(
      'builtin-errors',
      fields: {
        'root': root.path,
        'file': File('${root.path}/probe.dart').absolute.path,
        'timeoutMs': 20000,
      },
    );
    check(
      reply['ok'] == true && reply['builtinOnly'] == true,
      'Official startup failed',
    );
    final live = await control.send('status');
    snapshots.add(live);
    final ownerPid = live['pids'][0]['owner'] as int;
    check(
      ownerPid > 0 && ownerPid != pid && ownerPid != child.pid,
      'Invalid owned owner PID',
    );
    check(Process.killPid(ownerPid), 'Owner kill failed');
    ownerLost = true;
    await poll(() async => (await control.send('status'))['degraded'] != null);
    final degraded = await control.send('status');
    snapshots.add(degraded);
    check(
      degraded['slots'] == 1 && degraded['starts'] == 1,
      'Unconfirmed slot released',
    );
    final rejected = await control.send(
      'builtin-errors',
      fields: {
        'root': root.path,
        'file': File('${root.path}/probe.dart').absolute.path,
        'timeoutMs': 20000,
      },
    );
    check(rejected['ok'] == false, 'Degraded manager returned success');
    check(
      (await control.send('status'))['starts'] == 1,
      'Replacement started without Job zero',
    );
    passed = true;
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    try {
      await client?.send('shutdown');
      managerExit = await child.exitCode.timeout(const Duration(seconds: 25));
      check(
        ownerLost ? managerExit != 0 : managerExit == 0,
        'Unexpected manager exit',
      );
      check(!endpoint.existsSync(), 'Stale endpoint');
    } catch (error) {
      failure ??= error;
      child.kill();
    }
    client?.close();
    final stderrLog = await errors.timeout(const Duration(seconds: 5));
    final report = {
      'fixture': fixture.path,
      'allPassed': passed && failure == null,
      'skipped': skipped,
      'failure': failure?.toString(),
      'managerExit': managerExit,
      'jobZeroConfirmed': false,
      'snapshots': snapshots,
      'managerStderr': stderrLog,
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
