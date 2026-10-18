import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_analyzer_client.dart';
import 'worktree_disk_snapshot.dart';
import 'worktree_official_queue.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<bool> rejected(Future<dynamic> future) async {
  try {
    await future;
    return false;
  } catch (_) {
    return true;
  }
}

class ScriptedClient extends ResearchAnalyzerClient {
  ScriptedClient(super.root, super.log, this.hook);
  final Future<void> Function(String, Map) hook;
  final calls = <String>[];
  @override
  Future<Map> request(
    String method,
    Map params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    calls.add(
      method == 'analysis.getErrors'
          ? 'query'
          : params['files'].values.single['type'] as String,
    );
    await hook(method, params);
    return {
      'result': {'errors': []},
    };
  }
}

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-disk-snapshot-');
  final target = File('${fixture.path}/probe.dart');
  final results = <Map>[];
  Future<void> run(String name, Future<void> Function() body) async {
    await body();
    results.add({'name': name, 'passed': true});
    print('PASS $name');
  }

  await run('target hash catches same-length edits and deletion', () async {
    await target.writeAsString('int value = 1;');
    final original = ResearchDiskSnapshot.capture(fixture.path, target.path);
    original.validate(fixture.path);
    await target.writeAsString('int value = 2;');
    check(
      await rejected(Future.sync(() => original.validate(fixture.path))),
      'Same-length edit accepted',
    );
    await target.delete();
    check(
      await rejected(Future.sync(() => original.validate(fixture.path))),
      'Deletion accepted',
    );
  });
  await run(
    'same-content replacement changes file identity despite restored mtime',
    () async {
      await target.writeAsString('int value = 1;');
      final original = ResearchDiskSnapshot.capture(fixture.path, target.path);
      final mtime = target.lastModifiedSync();
      final replacement = File('${fixture.path}/replacement.dart');
      await replacement.writeAsString(original.content);
      await replacement.setLastModified(mtime);
      await target.rename('${fixture.path}/original-held.dart');
      await replacement.rename(target.path);
      final replaced = ResearchDiskSnapshot.capture(fixture.path, target.path);
      check(
        replaced.digest == original.digest &&
            replaced.fileIdentity != original.fileIdentity &&
            replaced.path == original.path &&
            replaced.stamp == original.stamp,
        'Replacement fixture failed',
      );
      check(
        await rejected(Future.sync(() => original.validate(fixture.path))),
        'Same-content replacement accepted',
      );
    },
  );
  await run(
    'outside root oversized and invalid UTF8 targets fail closed',
    () async {
      final inner = await Directory('${fixture.path}/inner').create();
      await target.writeAsString('int value = 1;');
      check(
        await rejected(
          Future.sync(
            () => ResearchDiskSnapshot.capture(inner.path, target.path),
          ),
        ),
        'Path escaped',
      );
      await target.writeAsBytes(List.filled(512 * 1024 + 1, 32));
      check(
        await rejected(
          Future.sync(
            () => ResearchDiskSnapshot.capture(fixture.path, target.path),
          ),
        ),
        'Large file accepted',
      );
      await target.writeAsBytes([255]);
      check(
        await rejected(
          Future.sync(
            () => ResearchDiskSnapshot.capture(fixture.path, target.path),
          ),
        ),
        'Invalid text accepted',
      );
    },
  );
  for (final phase in [
    'stable',
    'query-edit',
    'cleanup-edit',
    'cleanup-failure',
  ]) {
    await run(
      'pinned query $phase always removes temporary content before publishing',
      () async {
        await target.writeAsString('int value = 1;');
        final snapshot = ResearchDiskSnapshot.capture(
          fixture.path,
          target.path,
        );
        final client = ScriptedClient(
          fixture.path,
          File('${fixture.path}/unused'),
          (method, params) async {
            if (method == 'analysis.updateContent' &&
                params['files'].values.single['type'] == 'add') {
              check(
                params['files'].values.single['content'] == snapshot.content,
                'Wrong pinned text',
              );
            }
            if ((phase == 'query-edit' && method == 'analysis.getErrors') ||
                (phase == 'cleanup-edit' &&
                    method == 'analysis.updateContent' &&
                    params['files'].values.single['type'] == 'remove')) {
              await target.writeAsString('int value = 2;');
            }
            if (phase == 'cleanup-failure' &&
                method == 'analysis.updateContent' &&
                params['files'].values.single['type'] == 'remove') {
              throw StateError('Injected cleanup failure');
            }
          },
        );
        final query = researchBuiltinDiskQuery(client, snapshot);
        if (phase == 'stable') {
          check(
            (await query)['targetDigest'] == snapshot.digest,
            'Missing digest',
          );
        } else {
          check(await rejected(query), 'Stale or uncertain result published');
        }
        check(
          client.calls.join(',') == 'add,query,remove',
          'Cleanup not drained',
        );
      },
    );
  }
  await run(
    'queued cancellation and deadline skip transport while active work drains',
    () async {
      final queue = ResearchOfficialQueue();
      final gate = Completer<Map>();
      final activeCancel = Completer<void>();
      final active = rejected(
        queue.run(() => gate.future, cancelled: activeCancel.future),
      );
      await Future<void>.delayed(Duration.zero);
      final cancel = Completer<void>();
      var unexpected = 0;
      final pending = rejected(
        queue.run(() async {
          unexpected++;
          return {};
        }, cancelled: cancel.future),
      );
      final expired = rejected(
        queue.run(() async {
          unexpected++;
          return {};
        }, budget: const Duration(milliseconds: 5)),
      );
      cancel.complete();
      activeCancel.complete();
      check(
        await pending && await expired,
        'Queued work not rejected promptly',
      );
      var activeDone = false;
      unawaited(
        active.then((_) {
          activeDone = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      check(
        !activeDone && unexpected == 0,
        'Active lease released before transport drain',
      );
      final next = queue.run(() async => {'next': true});
      gate.complete({});
      check(
        await active && (await next)['next'] == true && unexpected == 0,
        'Queue recovery failed',
      );
    },
  );
  for (final mode in ['cancel', 'deadline']) {
    await run(
      'active $mode drains pinned protocol cleanup before next query',
      () async {
        await target.writeAsString('int value = 1;');
        final snapshot = ResearchDiskSnapshot.capture(
          fixture.path,
          target.path,
        );
        final reached = Completer<void>();
        final unblock = Completer<void>();
        final cancel = Completer<void>();
        final client = ScriptedClient(
          fixture.path,
          File('${fixture.path}/unused'),
          (method, params) async {
            if (method == 'analysis.getErrors') {
              reached.complete();
              await unblock.future;
            }
          },
        );
        final queue = ResearchOfficialQueue();
        var finished = false;
        final active = rejected(
          queue.run(
            () => researchBuiltinDiskQuery(client, snapshot),
            cancelled: mode == 'cancel' ? cancel.future : null,
            budget:
                mode == 'deadline' ? const Duration(milliseconds: 20) : null,
          ),
        );
        unawaited(
          active.then((_) {
            finished = true;
          }),
        );
        await reached.future;
        final next = queue.run(() async {
          check(
            client.calls.last == 'remove',
            'Next query entered before overlay cleanup',
          );
          return {'next': true};
        });
        cancel.complete();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        check(
          !finished && client.calls.join(',') == 'add,query',
          'Lease drained prematurely',
        );
        unblock.complete();
        check(
          await active && (await next)['next'] == true,
          'Active interruption published success',
        );
        check(
          client.calls.join(',') == 'add,query,remove',
          'Pinned text survived',
        );
      },
    );
  }
  await run(
    'queue capacity is bounded and zero budget sends nothing',
    () async {
      final queue = ResearchOfficialQueue();
      final gate = Completer<Map>();
      final pending = [
        for (var i = 0; i < 8; i++) queue.run(() => gate.future),
      ];
      check(await rejected(queue.run(() async => {})), 'Queue limit ignored');
      gate.complete({});
      await Future.wait(pending);
      var ran = false;
      check(
        await rejected(
              queue.run(() async {
                ran = true;
                return {};
              }, budget: Duration.zero),
            ) &&
            !ran,
        'Expired work sent',
      );
    },
  );
  final report = {
    'fixture': fixture.path,
    'allPassed': true,
    'results': results,
    'fakeProtocolOnly': true,
  };
  await File(
    '${fixture.path}/results.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  print(jsonEncode(report));
}
