import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_analyzer_client.dart';
import 'worktree_disk_observation.dart';
import 'worktree_manager_probe_check.dart' show check;

class ObservationPeer extends ResearchAnalyzerClient {
  ObservationPeer(super.root, super.log);
  Future<void> Function(String, Map)? hook;
  final operations = <String>[];
  void push(String path, List errors) {
    diagnostics.receive({
      'event': 'analysis.errors',
      'params': {'file': path, 'errors': errors},
    }, ++eventSequence);
  }

  void flush(String path) {
    diagnostics.receive({
      'event': 'analysis.flushResults',
      'params': {
        'files': [path],
      },
    }, ++eventSequence);
  }

  @override
  Future<Map> request(
    String method,
    Map params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    operations.add(
      method == 'analysis.getErrors'
          ? 'query'
          : params['files'].values.first['type'] as String,
    );
    await hook?.call(method, params);
    return {
      'result': {'errors': []},
    };
  }
}

Future<bool> rejects(Future<dynamic> value) async {
  try {
    await value;
    return false;
  } catch (_) {
    return true;
  }
}

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp(
    'dana-disk-observation-',
  );
  final file = File('${fixture.path}/probe.dart');
  final dependency = File('${fixture.path}/dependency.dart');
  await file.writeAsString('int value = 1;');
  await dependency.writeAsString('class Base {}');
  final results = <Map>[];
  Future<void> run(String name, Future<void> Function() body) async {
    await body();
    results.add({'name': name, 'passed': true});
    print('PASS $name');
  }

  await run(
    'bundle rejects duplicate outside-root excess dependencies and malformed expectations',
    () async {
      for (final inputs in [
        [file.path],
        List.filled(8, dependency.path),
        [123],
        ['${fixture.parent.path}/outside.dart'],
      ]) {
        check(
          await rejects(
            Future.sync(
              () => ResearchDiskBundle.capture(fixture.path, file.path, inputs),
            ),
          ),
          'Invalid inputs accepted',
        );
      }
      for (final codes in [
        null,
        ['Invalid Code'],
        List.filled(17, 'x'),
        [12],
      ]) {
        check(
          await rejects(Future.sync(() => researchExpectedCodes(codes))),
          'Invalid expectation accepted',
        );
      }
    },
  );
  for (final mode in [
    'missing',
    'stale',
    'fresh-empty',
    'flush-republish',
    'dependency-edit',
    'cleanup-failure',
  ]) {
    await run(
      '$mode observation respects freshness flush input validation and cleanup',
      () async {
        await dependency.writeAsString('class Base {}');
        final bundle = ResearchDiskBundle.capture(fixture.path, file.path, [
          dependency.path,
        ]);
        final peer = ObservationPeer(
          fixture.path,
          File('${fixture.path}/$mode.jsonl'),
        )..busy = false;
        final timers = <Timer>[];
        if (mode == 'stale') peer.push(bundle.target.path, []);
        peer.hook = (method, params) async {
          if (method == 'analysis.updateContent' &&
              params['files'].values.first['type'] == 'add') {
            if (mode != 'missing' && mode != 'stale') {
              peer.push(bundle.target.path, []);
            }
            if (mode == 'flush-republish') {
              timers.add(
                Timer(
                  const Duration(milliseconds: 100),
                  () => peer.flush(bundle.target.path),
                ),
              );
              timers.add(
                Timer(
                  const Duration(milliseconds: 300),
                  () => peer.push(bundle.target.path, []),
                ),
              );
            }
            if (mode == 'dependency-edit') {
              timers.add(
                Timer(
                  const Duration(milliseconds: 70),
                  () => dependency.writeAsStringSync('class Nope {}'),
                ),
              );
            }
          }
          if (mode == 'cleanup-failure' &&
              method == 'analysis.updateContent' &&
              params['files'].values.first['type'] == 'remove') {
            throw StateError('Injected cleanup failure');
          }
        };
        try {
          final observed = researchObserveDisk(
            peer,
            bundle,
            [],
            observationTimeout: const Duration(milliseconds: 850),
          );
          if (mode == 'fresh-empty' || mode == 'flush-republish') {
            final result = await observed;
            check(
              result['observationOnly'] == true &&
                  (result['pushSequence'] as int) >
                      (result['sinceSequence'] as int),
              'No fresh observation',
            );
            if (mode == 'flush-republish') {
              check(
                (result['observationMs'] as int) >= 550,
                'Flush bypassed stable window',
              );
            }
          } else {
            check(await rejects(observed), 'Uncertain result accepted');
          }
          check(
            peer.operations.join(',') == 'add,query,remove',
            'Temporary inputs not cleaned',
          );
        } finally {
          for (final timer in timers) {
            timer.cancel();
          }
        }
      },
    );
  }
  final report = {
    'fixture': fixture.path,
    'allPassed': true,
    'fakeProtocolOnly': true,
    'results': results,
  };
  await File(
    '${fixture.path}/results.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  print(jsonEncode(report));
}
