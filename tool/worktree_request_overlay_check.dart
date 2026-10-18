import 'dart:convert';
import 'dart:io';
import 'worktree_disk_observation.dart';
import 'worktree_disk_observation_check.dart' show ObservationPeer, rejects;
import 'worktree_manager_probe_check.dart' show check;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp(
    'dana-request-overlay-',
  );
  final target = File('${fixture.path}/probe.dart');
  final dependency = File('${fixture.path}/dependency.dart');
  final other = File('${fixture.path}/undeclared.dart');
  await target.writeAsString('int value = diskMissing;');
  await dependency.writeAsString('class DiskBase {}');
  await other.writeAsString('class Other {}');
  final results = <Map>[];
  Future<void> run(String name, Future<void> Function() body) async {
    await body();
    results.add({'name': name, 'passed': true});
    print('PASS $name');
  }

  ResearchDiskBundle bundle() =>
      ResearchDiskBundle.capture(fixture.path, target.path, [dependency.path]);
  await run(
    'reject malformed undeclared alias duplicate Unicode and oversized overlays',
    () async {
      final inputs = bundle();
      for (final bad in [
        null,
        [],
        {target.path: 3},
        {other.path: 'text'},
        {target.path: 'x', '${fixture.path}/./probe.dart': 'y'},
        {target.path: String.fromCharCode(0xd800)},
        {target.path: 'x' * (512 * 1024 + 1)},
        {target.path: '中' * (180 * 1024)},
      ]) {
        check(
          await rejects(
            Future.sync(() => ResearchRequestOverlay.capture(inputs, bad)),
          ),
          'Invalid overlay accepted',
        );
      }
    },
  );
  for (final mode in [
    'replace-target',
    'replace-dependency',
    'clear',
    'missing-push',
    'add-failure',
    'cleanup-failure',
    'disk-replacement',
  ]) {
    await run(
      '$mode snapshot is isolated and cleanup precedes publication',
      () async {
        final inputs = bundle();
        final raw = <String, String>{
          if (mode == 'replace-target')
            target.path: 'int value = unsavedMissing;',
          if (mode != 'clear') dependency.path: 'class UnsavedBase {}',
        };
        final snapshot = ResearchRequestOverlay.capture(inputs, raw);
        final digest = snapshot.digest;
        raw.clear(); // Caller mutation cannot change an accepted snapshot.
        check(snapshot.digest == digest, 'Mutable snapshot');
        final peer = ObservationPeer(
          fixture.path,
          File('${fixture.path}/$mode.jsonl'),
        )..busy = false;
        var cleaned = false;
        peer.hook = (method, params) async {
          if (method == 'analysis.updateContent') {
            final files = params['files'] as Map;
            check(files.length == 2, 'Declared dependency omitted');
            if (files.values.first['type'] == 'add') {
              for (final input in inputs.inputs) {
                check(
                  files[input.path]['content'] ==
                      snapshot.effectiveFiles[input.path],
                  'Wrong effective content',
                );
              }
              if (mode == 'add-failure') throw StateError('Uncertain apply');
            } else {
              check(
                files.values.every((v) => v['type'] == 'remove'),
                'Incomplete remove',
              );
              cleaned = true;
              if (mode == 'cleanup-failure') {
                throw StateError('Uncertain cleanup');
              }
            }
          } else if (mode != 'missing-push') {
            if (mode == 'disk-replacement') {
              final replacement = File('${fixture.path}/new.dart');
              await replacement.writeAsString(dependency.readAsStringSync());
              await replacement.setLastModified(dependency.lastModifiedSync());
              await dependency.rename('${fixture.path}/old.dart');
              await replacement.rename(dependency.path);
            }
            peer.push(inputs.target.path, []);
          }
        };
        final query = researchObserveDisk(
          peer,
          inputs,
          [],
          overlay: snapshot,
          observationTimeout: const Duration(milliseconds: 400),
        );
        if ([
          'missing-push',
          'add-failure',
          'cleanup-failure',
          'disk-replacement',
        ].contains(mode)) {
          check(await rejects(query), 'Failed operation published success');
        } else {
          final result = await query;
          check(
            result['observationOnly'] == true &&
                result['overlayScope'] == 'request-only' &&
                result['overlaySnapshotDigest'] == digest &&
                result['effectiveInputDigest'] == snapshot.effectiveDigest,
            'Incorrect overlay confirmation',
          );
          inputs.validate(fixture.path);
        }
        check(
          cleaned && peer.operations.last == 'remove',
          'Cleanup not awaited',
        );
        check(
          await target.readAsString() == 'int value = diskMissing;' &&
              await dependency.readAsString() == 'class DiskBase {}',
          'Disk modified',
        );
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
