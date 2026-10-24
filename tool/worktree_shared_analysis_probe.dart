// Research only. Does not alter SDK, plugins, product routing or user worktrees.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length < 2) {
    throw ArgumentError(
      'probe.dart <absolute-dart.exe> <new-report.json> [files=800] [rounds=2] [roots=3] [source-repo]',
    );
  }
  final sdk = File(args[0]).absolute.path;
  final destination = File(args[1]);
  if (destination.existsSync()) throw StateError('Refuse to overwrite report');
  final count = args.length > 2 ? int.parse(args[2]) : 800;
  final rounds = args.length > 3 ? int.parse(args[3]) : 2;
  final rootCount = args.length > 4 ? int.parse(args[4]) : 3;
  final sourceRepository = args.length > 5 ? Directory(args[5]).absolute : null;
  if (count < 1 || count > 20000 || rounds < 1 || rounds > 4)
    throw ArgumentError('probe bounds');
  if (rootCount < 2 || rootCount > 3)
    throw ArgumentError('root count must be 2 or 3');
  if (sourceRepository != null && !await sourceRepository.exists()) {
    throw ArgumentError('source repository does not exist');
  }
  final sampler = WindowsSystemMemorySampler();
  final startReserveMiB =
      int.tryParse(
        Platform.environment['DANA_PROBE_START_RESERVE_MIB'] ?? '',
      ) ??
      5120;
  final runReserveMiB =
      int.tryParse(Platform.environment['DANA_PROBE_RUN_RESERVE_MIB'] ?? '') ??
      4096;
  final maxAnalyzerMiB =
      int.tryParse(Platform.environment['DANA_PROBE_MAX_ANALYZER_MIB'] ?? '') ??
      2048;
  if (startReserveMiB < 1024 ||
      runReserveMiB < 1024 ||
      maxAnalyzerMiB < 1024 ||
      runReserveMiB > startReserveMiB) {
    throw ArgumentError('invalid memory guard environment');
  }
  final daemons = <AnalyzerDaemon>[];
  final processes = <WindowsFfiAnalyzerProcess>[];
  final rows = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'date': DateTime.now().toUtc().toIso8601String(),
    'sdk': sdk,
    'minimumFilesPerRoot': count,
    'fixtureType': sourceRepository == null ? 'synthetic' : 'repository',
    'rootCount': rootCount,
    'rounds': rounds,
    'rows': rows,
    'passed': false,
    'scope':
        'same-repo Git worktrees; builtin errors; private commit, not retained Dart heap; serial requests',
  };
  void save() => destination.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  String? failure;
  var stage = 'prepare';
  String? guardFailure;
  var peak = 0.0;
  var minCommit = double.infinity;
  double memory() {
    var total = 0.0;
    for (final p in processes) {
      final sample = p.sampleResources();
      if (sample['complete'] != true || sample['currentPrivateMiB'] is! num)
        throw StateError('incomplete Job sample');
      total += (sample['currentPrivateMiB'] as num).toDouble();
    }
    return total;
  }

  void guard({bool starting = false}) {
    final s = sampler.sample();
    if (s == null) throw StateError('Unknown memory headroom');
    final threshold =
        (starting ? startReserveMiB : runReserveMiB) * bytesPerMiB;
    final commit = s.availableCommitBytes / bytesPerMiB;
    if (commit < minCommit) minCommit = commit;
    final total = memory();
    if (total > peak) peak = total;
    if (s.availablePhysicalBytes < threshold ||
        s.availableCommitBytes < threshold ||
        total > maxAnalyzerMiB) {
      throw StateError('memory guard: commit=$commit own=$total MiB');
    }
  }

  Future<void> closeAll() async {
    Object? error;
    for (final d in daemons.reversed) {
      try {
        await d.close();
      } catch (e) {
        error ??= e;
      }
    }
    for (final p in processes) {
      try {
        await p.terminate();
        if (!p.confirmedEmpty) throw StateError('Job not empty');
      } catch (e) {
        error ??= e;
      }
    }
    daemons.clear();
    processes.clear();
    if (error != null) throw StateError('Cleanup: $error');
  }

  Future<String> git(String root, List<String> args) async {
    final r = await Process.run('git', ['-C', root, ...args]);
    if (r.exitCode != 0) throw StateError('git $args: ' + r.stderr.toString());
    return r.stdout.toString().trim();
  }

  Timer? monitor;
  try {
    guard(starting: true);
    final temp = await Directory.systemTemp.createTemp('dana-sharing-');
    report['fixture'] = temp.path;
    final repo = Directory(temp.path + '/repo');
    final root = repo.path;
    if (sourceRepository == null) {
      repo.createSync();
      Directory('$root/lib').createSync();
      File('$root/.gitignore').writeAsStringSync('.dart_tool/\n');
      File('$root/pubspec.yaml').writeAsStringSync(
        'name: share_fixture\nenvironment:\n  sdk: ">=3.7.0 <4.0.0"\n',
      );
      File(
        '$root/lib/unit_0.dart',
      ).writeAsStringSync('class Unit0 { int value() => 0; }\n');
      for (var i = 1; i < count; i++) {
        File('$root/lib/unit_$i.dart').writeAsStringSync(
          "import 'unit_0.dart';\nclass Unit$i extends Unit0 { int own() => $i; }\n",
        );
      }
      File(
        '$root/lib/dependency.dart',
      ).writeAsStringSync('const selected = 7;\n');
      File('$root/lib/probe.dart').writeAsStringSync(
        "import 'package:share_fixture/dependency.dart';\nint checked = selected;\n",
      );
      File('$root/lib/marker.dart').writeAsStringSync('int branch = 0;\n');
    } else {
      report['sourceRepository'] = sourceRepository.path;
      final clone = await Process.run('git', [
        'clone',
        '--shared',
        '--no-checkout',
        sourceRepository.path,
        root,
      ]);
      if (clone.exitCode != 0) {
        throw StateError('git clone failed: ${clone.stderr}');
      }
    }
    final commit = [
      '-c',
      'user.name=Research Fixture',
      '-c',
      'user.email=fixture@localhost',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '--quiet',
      '-m',
      'Synthetic research fixture',
    ];
    if (sourceRepository == null) {
      await git(root, ['init', '--quiet']);
      await git(root, ['add', '.']);
      await git(root, commit);
    }
    final roots = <String>[];
    for (var i = 0; i < rootCount; i++) {
      final branchPath = Directory(temp.path + '/branch_$i').absolute.path;
      await git(root, [
        'worktree',
        'add',
        '--quiet',
        '-b',
        'research_$i',
        branchPath,
      ]);
      final branch = Directory(branchPath).resolveSymbolicLinksSync();
      roots.add(branch);
      if (sourceRepository == null) {
        final cfg = File('$branch/.dart_tool/package_config.json')
          ..parent.createSync();
        cfg.writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'share_fixture',
                'rootUri': '../',
                'packageUri': 'lib/',
                'languageVersion': '3.7',
              },
            ],
          }),
        );
        if (i > 0) {
          File('$branch/lib/dependency.dart').writeAsStringSync(
            i == 1
                ? "const selected = 'branch1';\n"
                : 'const selected = false;\n',
          );
          File(
            '$branch/lib/marker.dart',
          ).writeAsStringSync('int branch = missingBranch$i;\n');
          await git(branch, ['add', 'lib']);
          await git(branch, commit);
        }
      } else {
        final marker = 'pkg/analyzer/tool/dana_worktree_probe_$i.dart';
        File('$branch/$marker').writeAsStringSync(
          'int probeBranch$i = missingDartWorktreeSymbol$i;\n',
        );
        await git(branch, ['add', marker]);
        await git(branch, commit);
        final pub = await Process.run(sdk, [
          'pub',
          'get',
        ], workingDirectory: branch);
        if (pub.exitCode != 0) {
          throw StateError('pub get failed in $branch: ${pub.stderr}');
        }
      }
    }
    final common = <String>{};
    for (final r in roots) {
      common.add(
        await git(r, [
          'rev-parse',
          '--path-format=absolute',
          '--git-common-dir',
        ]),
      );
    }
    if (common.length != 1) throw StateError('Not same repository');
    report['gitCommonDir'] = common.single;
    report['worktrees'] = roots;
    save();
    monitor = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (failure != null) return;
      try {
        guard();
      } catch (e) {
        failure = '$e';
        guardFailure = '$e';
        report['guardFailure'] = guardFailure;
        report['failureStage'] = stage;
        save();
        for (final p in processes) {
          p.terminate().ignore();
        }
      }
    });
    Future<AnalyzerDaemon> start(String path) async {
      stdout.writeln('starting analyzer for $path');
      guard(starting: true);
      final d = AnalyzerDaemon(
        path,
        ownedProcessStarter: () async {
          final p = await WindowsFfiAnalyzerProcess.start(sdk, [
            'language-server',
            '--protocol=analyzer',
            '--client-id=dana-sharing-research',
          ], workingDirectory: path);
          processes.add(p);
          return p;
        },
      );
      daemons.add(d);
      await d.start();
      stdout.writeln('analyzer roots ready: $path');
      return d;
    }

    Future<void> verify(
      AnalyzerDaemon d,
      String target,
      int branch, {
      bool overlay = false,
    }) async {
      if (sourceRepository != null) {
        final path = File(
          '$target/pkg/analyzer/tool/dana_worktree_probe_$branch.dart',
        ).absolute.path.replaceAll('/', r'\');
        final result = await d.handle({
          'op': 'check',
          'files': [path],
        });
        final text = jsonEncode(result['diagnostics']);
        if (result['ok'] != true ||
            result['errors'] != 1 ||
            !text.contains('missingDartWorktreeSymbol$branch')) {
          throw StateError('Repository branch $branch failed: $result');
        }
        return;
      }
      final files = <Object>[];
      for (final name in ['dependency.dart', 'marker.dart', 'probe.dart']) {
        final path = File(
          '$target/lib/$name',
        ).absolute.path.replaceAll('/', r'\');
        files.add(
          overlay
              ? {
                'path': path,
                'content':
                    File(roots[branch] + '/lib/$name').readAsStringSync(),
              }
              : path,
        );
      }
      final r = await d.handle({'op': 'check', 'files': files});
      final text = jsonEncode(r['diagnostics']);
      if (r['ok'] != true ||
          r['errors'] != (branch == 0 ? 0 : 2) ||
          (branch > 0 &&
              (!text.contains('missingBranch$branch') ||
                  !text.contains(branch == 1 ? 'String' : 'bool')))) {
        throw StateError('Branch $branch failed: $r');
      }
    }

    Map<String, Object?> validateFullCheck(
      Map<String, Object?> result,
      String root,
      int minimumFiles,
    ) {
      if (result['ok'] != true ||
          (result['files'] as int? ?? 0) < minimumFiles) {
        throw StateError(
          'Full check did not cover the fixture: root=$root result=$result expectedAtLeast=$minimumFiles files',
        );
      }
      stdout.writeln(
        'fullCheck ${root}: ${result['files']} files, ${result['elapsedMs']} ms',
      );
      return result;
    }

    Future<Map<String, Object?>> fullCheck(
      AnalyzerDaemon daemon,
      String root,
    ) async {
      stage = 'fullCheck $root';
      save();
      final request = daemon.handle({'op': 'fullCheck', 'root': root});
      final processExit = Future.any<Object?>(
        processes.map(
          (process) => process.exitCode.then<Object?>(
            (code) => {'processExitCode': code, 'pid': process.pid},
          ),
        ),
      );
      final watch = Stopwatch()..start();
      while (true) {
        final completed = await Future.any<Object?>([
          request,
          processExit,
          Future<Object?>.delayed(const Duration(seconds: 1)),
        ]);
        if (completed != null) {
          if (completed is! Map<String, Object?>) {
            throw StateError('Unexpected fullCheck response: $completed');
          }
          if (completed.containsKey('processExitCode')) {
            throw StateError('Analyzer exited during fullCheck: $completed');
          }
          return validateFullCheck(completed, root, count);
        }
        guard();
        if (watch.elapsed > const Duration(minutes: 30)) {
          throw TimeoutException('fullCheck timed out for $root');
        }
      }
    }

    for (var round = 0; round < rounds; round++) {
      final modes =
          sourceRepository != null
              ? ['multi', 'independent']
              : count > 5000
              ? ['multi', 'independent']
              : round.isEven
              ? ['single', 'independent', 'multi', 'canonical']
              : ['canonical', 'multi', 'independent', 'single'];
      for (final mode in modes) {
        stage = 'round ${round + 1} $mode';
        if (failure != null) throw StateError(failure!);
        peak = 0;
        final watch = Stopwatch()..start();
        final switches = <Map<String, Object?>>[];
        final fullChecks = <Map<String, Object?>>[];
        if (mode == 'independent') {
          for (var i = 0; i < roots.length; i++) {
            final d = await start(roots[i]);
            fullChecks.add(await fullCheck(d, roots[i]));
            await verify(d, roots[i], i);
          }
        } else {
          final d = await start(roots.first);
          if (mode == 'multi') {
            if (sourceRepository != null) {
              fullChecks.add(await fullCheck(d, roots.first));
              await verify(d, roots.first, 0);
            }
            for (final r in roots.skip(1)) {
              await d.addRoot(r);
            }
          }
          if (mode == 'multi') {
            for (
              var i = sourceRepository == null ? 0 : 1;
              i < roots.length;
              i++
            ) {
              fullChecks.add(await fullCheck(d, roots[i]));
              await verify(d, roots[i], i);
            }
          } else if (mode == 'canonical') {
            fullChecks.add(await fullCheck(d, roots.first));
            for (final i in [0, 1, 2, 1, 0, 2, 0]) {
              final sw = Stopwatch()..start();
              await verify(d, roots.first, i, overlay: true);
              switches.add({'branch': i, 'elapsedMs': sw.elapsedMilliseconds});
            }
            await d.handle({
              'op': 'clearContent',
              'files': [
                for (final n in [
                  'dependency.dart',
                  'marker.dart',
                  'probe.dart',
                ])
                  File(
                    roots.first + '/lib/$n',
                  ).absolute.path.replaceAll('/', r'\'),
              ],
            });
            await verify(d, roots.first, 0);
          } else {
            fullChecks.add(await fullCheck(d, roots.first));
            await verify(d, roots.first, 0);
          }
        }
        final readyMs = watch.elapsedMilliseconds;
        final samples = <double>[];
        for (var i = 0; i < 7; i++) {
          guard();
          samples.add(memory());
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        samples.sort();
        final row = <String, Object?>{
          'round': round + 1,
          'mode': mode,
          'servers': processes.length,
          'readyAndChecksMs': readyMs,
          'postCheckMedianPrivateMiB': samples[3],
          'sampledPeakPrivateMiB': peak,
          'switches': switches,
          'fullCheckFiles': [for (final check in fullChecks) check['files']],
          'verified': true,
        };
        // Sampling must not race termination of a Job being reclaimed.
        monitor?.cancel();
        await closeAll();
        row['allJobsConfirmedEmpty'] = true;
        monitor = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (failure != null) return;
          try {
            guard();
          } catch (e) {
            failure = '$e';
            for (final p in processes) {
              p.terminate().ignore();
            }
          }
        });
        rows.add(row);
        save();
        stdout.writeln(jsonEncode(row));
      }
    }
    if (failure != null) throw StateError(failure!);
    report['passed'] = true;
  } catch (e, st) {
    report['error'] = '$e';
    report['primaryFailure'] = failure;
    report['failureStage'] = stage;
    report['guardFailure'] = guardFailure;
    report['stack'] = '$st';
    exitCode = 1;
  } finally {
    monitor?.cancel();
    try {
      await closeAll();
      report['cleanupConfirmed'] = true;
    } catch (e) {
      report['cleanupError'] = '$e';
      report['passed'] = false;
      exitCode = 1;
    }
    Map<String, Object?>? sharedRow;
    Map<String, Object?>? independentRow;
    for (final row in rows) {
      if (row['mode'] == 'multi') sharedRow = row;
      if (row['mode'] == 'independent') independentRow = row;
    }
    if (sharedRow != null && independentRow != null) {
      final sharedMiB = sharedRow['postCheckMedianPrivateMiB'] as num;
      final independentMiB = independentRow['postCheckMedianPrivateMiB'] as num;
      final savedMiB = independentMiB - sharedMiB;
      report['memoryComparison'] = {
        'independentWorkersMiB': independentMiB,
        'sharedMultiRootMiB': sharedMiB,
        'savedMiB': savedMiB,
        'savedPercent':
            independentMiB == 0 ? null : savedMiB / independentMiB * 100,
        'metric': 'sum of analyzer Job private commit after checks settle',
      };
    }
    report['minimumAvailableCommitMiB'] = minCommit.isFinite ? minCommit : null;
    save();
    stdout.writeln(
      'Report: ' + destination.path + '; passed=' + report['passed'].toString(),
    );
  }
}
