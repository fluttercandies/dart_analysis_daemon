// Real plugin through global manager; request-scoped overlays only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_manager_probe_check.dart' show Client, check, poll;

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Supply warmed plugin disk project');
  }
  final template = Directory(args.single).resolveSymbolicLinksSync();
  final fixture = await Directory.systemTemp.createTemp(
    'dana-official-request-overlay-',
  );
  final root = await Directory('${fixture.path}/project').create();
  for (final path in [
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    '.dart_tool/package_config.json',
    '.dart_tool/package_graph.json',
    'lib/probe.dart',
    'lib/dependency.dart',
  ]) {
    final output = File('${root.path}/$path');
    await output.parent.create(recursive: true);
    await File('$template/$path').copy(output.path);
  }
  final target = File('${root.path}/lib/probe.dart');
  final dependency = File('${root.path}/lib/dependency.dart');
  final originalTarget = await target.readAsString();
  final originalDependency = await dependency.readAsString();
  const clean =
      "import 'dependency.dart';\nclass Plain extends AllowedBase {}\nint value = 1;\n";
  const allowed =
      'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = AllowedBase;\n';
  const all = [
    'undefined_identifier',
    'dynamic_syntax_probe',
    'dynamic_semantic_probe',
  ];
  const noSemantic = ['undefined_identifier', 'dynamic_syntax_probe'];
  final other = await Directory('${fixture.path}/other').create();
  final otherFile = File('${other.path}/probe.dart');
  await otherFile.writeAsString('int value = missingOther;');
  final manager = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--official-worker',
    '--system-memory',
    '--official-request-overlays',
    '--official-fault-gates',
  ]);
  final ready = Completer<void>();
  manager.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (!ready.isCompleted && jsonDecode(line)['event'] == 'ready') {
        ready.complete();
      }
    },
  );
  final stderr = manager.stderr.transform(utf8.decoder).join();
  final peers = <Client>[];
  final results = <Map>[];
  final snapshots = <Map>[];
  final evidence = <Map>[];
  Object? failure;
  Timer? sampler;
  var sampling = false;
  var skipped = false;
  var shutdown = false;
  late Client admin;
  late Map metadata;
  Future<Client> connect() async {
    final peer = await Client.connect(metadata);
    peers.add(peer);
    return peer;
  }

  Future<Map> query(
    Client peer,
    Map<String, String> overrides,
    List<String> codes, {
    int timeout = 180000,
  }) => peer.send(
    'observe-overlay',
    fields: {
      'root': root.path,
      'file': target.absolute.path,
      'dependencies': [dependency.absolute.path],
      'overlays': overrides,
      'expectedCodes': codes,
      'timeoutMs': timeout,
    },
    responseTimeout: const Duration(seconds: 190),
  );
  void valid(Map result, List<String> codes) {
    final actual =
        (result['errors'] as List?)?.map((e) => '${e['code']}').toList();
    actual?.sort();
    final expected = List.of(codes)..sort();
    check(
      result['ok'] == true &&
          result['overlayScope'] == 'request-only' &&
          result['observationOnly'] == true &&
          result['diagnosticComplete'] == false &&
          result['synthetic'] == false &&
          jsonEncode(actual) == jsonEncode(expected),
      'Wrong real overlay result: $result',
    );
  }

  Future<void> unchanged() async {
    check(
      await target.readAsString() == originalTarget &&
          await dependency.readAsString() == originalDependency,
      'Disk source changed',
    );
  }

  Future<void> run(String name, Future<Map> Function() action) async {
    final watch = Stopwatch()..start();
    final result = await action();
    await unchanged();
    results.add({
      'name': name,
      'passed': true,
      'elapsedMs': watch.elapsedMilliseconds,
      'response': result,
    });
    print('PASS $name');
  }

  try {
    await ready.future.timeout(const Duration(seconds: 15));
    metadata =
        jsonDecode(await File('${fixture.path}/manager.json').readAsString())
            as Map;
    admin = await connect();
    final initial = await admin.send('status');
    snapshots.add(initial);
    check(initial['officialRequestOverlays'] == true, 'Opt-in absent');
    if (initial['memory']['allowed'] != true) {
      skipped = true;
      print('SKIP real memory admission');
      return;
    }
    sampler = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (sampling || snapshots.length >= 4096) return;
      sampling = true;
      try {
        snapshots.add(await admin.send('status'));
      } catch (_) {
      } finally {
        sampling = false;
      }
    });
    final first = await connect();
    Future<Map> checked(
      Client peer,
      Map<String, String> files,
      List<String> codes,
    ) async {
      final result = await query(peer, files, codes);
      valid(result, codes);
      return result;
    }

    await run(
      'empty request snapshot observes disk diagnostics',
      () => checked(first, {}, all),
    );
    final second = await connect();
    await run(
      'unsaved target clears all diagnostics without saving',
      () => checked(first, {target.absolute.path: clean}, []),
    );
    await run(
      'another client observes disk after previous request cleanup',
      () => checked(second, {}, all),
    );
    await run(
      'unsaved dependency updates semantic plugin diagnostics',
      () => checked(first, {dependency.absolute.path: allowed}, noSemantic),
    );
    await run(
      'empty snapshot restores disk dependency semantics',
      () => checked(first, {}, all),
    );
    await run(
      'concurrent clients have independent serialized snapshots',
      () async {
        final both = await Future.wait([
          checked(first, {dependency.absolute.path: allowed}, noSemantic),
          checked(second, {target.absolute.path: clean}, []),
        ]);
        return {'responses': both};
      },
    );
    final hold = File('${fixture.path}/official-query.hold');
    final reached = File('${fixture.path}/official-query.reached');
    for (final mode in ['cancel', 'disconnect', 'deadline']) {
      await run(
        'active $mode drains overlay cleanup before next client',
        () async {
          if (reached.existsSync()) await reached.delete();
          await hold.writeAsString('hold', flush: true);
          final peer = await connect();
          final active = query(
            peer,
            {target.absolute.path: clean},
            [],
            timeout: mode == 'deadline' ? 1800 : 20000,
          ).then<Map>((v) => v, onError: (Object e) => {'disconnected': '$e'});
          final requestId = '${peer.sequence}';
          await poll(() async => reached.existsSync());
          final gate = jsonDecode(await reached.readAsString()) as Map;
          final log = File(gate['protocolLog'] as String);
          if (mode == 'cancel') {
            check(
              (await peer.send(
                    'cancel',
                    fields: {'target': requestId},
                  ))['found'] ==
                  true,
              'Cancel missing',
            );
          } else if (mode == 'disconnect') {
            peer.close();
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 1900));
          }
          var followerDone = false;
          final follower = checked(second, {}, all).then((v) {
            followerDone = true;
            return v;
          });
          await Future<void>.delayed(const Duration(milliseconds: 100));
          check(!followerDone, 'Follower bypassed held overlay');
          await hold.delete();
          final interrupted = await active;
          check(
            mode == 'disconnect'
                ? interrupted.containsKey('disconnected')
                : interrupted['ok'] == false && peer.counts[requestId] == 1,
            'Interrupted result accepted',
          );
          valid(await follower, all);
          final events =
              log.readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
          final held = events.lastIndexWhere(
            (e) => e['faultGate'] == 'held' && e['id'] == gate['id'],
          );
          final cleanup = events.indexWhere(
            (e) => e['requestOverlayObservation'] == 'cleanupAck',
            held + 1,
          );
          final next = events.indexWhere(
            (e) => e['requestOverlayObservation'] == 'begin',
            held + 1,
          );
          check(
            held >= 0 && cleanup > held && next > cleanup,
            'Overlay cleanup order wrong',
          );
          evidence.add({
            'mode': mode,
            'log': log.path,
            'held': held,
            'cleanup': cleanup,
            'next': next,
          });
          return {'interrupted': interrupted, 'cleanupBeforeNext': true};
        },
      );
    }
    final before = (await admin.send('status'))['starts'] as int;
    await File(
      '${root.path}/analysis_options.yaml',
    ).writeAsString('\n# environment change\n', mode: FileMode.append);
    await run(
      'configuration rebuild replays complete request snapshot',
      () => checked(first, {target.absolute.path: clean}, []),
    );
    check(
      (await admin.send('status'))['starts'] == before + 1,
      'No environment replacement',
    );
    await run(
      'cross-root replacement returns ordinary built-in errors',
      () async {
        final result = await second.send(
          'builtin-errors',
          fields: {
            'root': other.path,
            'file': otherFile.absolute.path,
            'timeoutMs': 20000,
          },
        );
        check(
          result['ok'] == true && result['builtinOnly'] == true,
          'Other root failed',
        );
        return result;
      },
    );
    await run(
      'returning root replays unsaved dependency into fresh plugin worker',
      () => checked(first, {dependency.absolute.path: allowed}, noSemantic),
    );
    await run(
      'final empty request confirms disk state restored',
      () => checked(second, {}, all),
    );
    sampler.cancel();
    await admin.send('shutdown');
    check(
      await manager.exitCode.timeout(const Duration(seconds: 25)) == 0 &&
          !File('${fixture.path}/manager.json').existsSync(),
      'Shutdown not confirmed',
    );
    shutdown = true;
  } catch (error) {
    failure = error;
    if (peers.isNotEmpty) {
      try {
        snapshots.add(await admin.send('status'));
      } catch (_) {}
    }
    print('FAIL $error');
  } finally {
    sampler?.cancel();
    if (!shutdown) {
      try {
        if (peers.isNotEmpty) await admin.send('shutdown');
        shutdown =
            await manager.exitCode.timeout(const Duration(seconds: 25)) == 0;
      } catch (error) {
        failure ??= error;
        manager.kill();
      }
    }
    for (final peer in peers) {
      peer.close();
    }
    final report = {
      'fixture': fixture.path,
      'template': template,
      'allPassed':
          failure == null && !skipped && shutdown && results.length == 13,
      'skipped': skipped,
      'failure': failure?.toString(),
      'shutdownConfirmed': shutdown,
      'results': results,
      'evidence': evidence,
      'snapshots': snapshots,
      'managerStderr': await stderr,
    };
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(
      jsonEncode({
        'fixture': fixture.path,
        'allPassed': report['allPassed'],
        'failure': report['failure'],
        'shutdownConfirmed': shutdown,
      }),
    );
    if (failure != null) exitCode = 1;
  }
}
