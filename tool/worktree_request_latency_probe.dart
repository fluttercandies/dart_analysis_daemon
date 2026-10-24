// Research only. Measures hot requests on real Dart SDK source worktrees.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 3) {
    throw ArgumentError(
      'probe.dart <absolute-dart.exe> <source-repo> <new-report.json>',
    );
  }
  final sdk = File(args[0]).absolute.path;
  final source = Directory(args[1]).absolute.path;
  final reportFile = File(args[2]);
  if (reportFile.existsSync()) throw StateError('Refuse to overwrite report');
  final report = <String, Object?>{
    'date': DateTime.now().toUtc().toIso8601String(),
    'sdk': sdk,
    'sourceRepository': source,
    'fixtureType':
        'real Dart SDK worktrees, scoped to pkg/analyzer; builtin analyzer only',
    'analysisRoot': 'pkg/analyzer',
    'directory': 'lib/src/dart/analysis',
    'directoryDartFiles': 40,
    'samplesPerRequestPerSession': 15,
    'sessionsPerMode': 3,
    'rows': <Map<String, Object?>>[],
    'passed': false,
  };
  void save() => reportFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(report),
  );

  Future<String> git(String cwd, List<String> args) async {
    final result = await Process.run('git', ['-C', cwd, ...args]);
    if (result.exitCode != 0) {
      throw StateError('git $args failed: ${result.stderr}');
    }
    return result.stdout.toString().trim();
  }

  final temp = await Directory.systemTemp.createTemp('dana-latency-');
  final roots = ['${temp.path}\\root_0', '${temp.path}\\root_1'];
  final worktreePaths = <String>[];
  try {
    report['temporaryDirectory'] = temp.path;
    final head = await git(source, ['rev-parse', 'HEAD']);
    report['sourceHead'] = head;
    for (var i = 0; i < roots.length; i++) {
      await git(source, [
        'worktree',
        'add',
        '--quiet',
        '--detach',
        roots[i],
        head,
      ]);
      worktreePaths.add(roots[i]);
    }
    final targetFile =
        r'lib\src\dart\analysis\analysis_context_collection.dart';
    final targetDirectory = r'lib\src\dart\analysis';
    final sessions = <({String mode, int index})>[
      for (var i = 0; i < 3; i++)
        if (i.isEven) ...[
          (mode: 'single', index: i),
          (mode: 'multi', index: i),
        ] else ...[
          (mode: 'multi', index: i),
          (mode: 'single', index: i),
        ],
    ];
    final rows = report['rows']! as List<Map<String, Object?>>;
    final memorySampler = WindowsSystemMemorySampler();
    double availableCommitMiB() {
      final sample = memorySampler.sample();
      if (sample == null) throw StateError('Unable to sample system memory');
      return sample.availableCommitBytes / bytesPerMiB;
    }

    Future<void> waitUntilIdle(AnalyzerDaemon daemon) async {
      final timer = Stopwatch()..start();
      var idleSamples = 0;
      while (timer.elapsed < const Duration(minutes: 10)) {
        if (availableCommitMiB() < 2048) {
          throw StateError('Memory guard: less than 2 GiB commit available');
        }
        final status = await daemon.handle({'op': 'status'});
        if (status['healthy'] != true) {
          throw StateError('Analyzer unhealthy: $status');
        }
        if (status['isAnalyzing'] == false) {
          if (++idleSamples >= 3) return;
        } else {
          idleSamples = 0;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw TimeoutException('Analyzer did not become idle');
    }

    for (final session in sessions) {
      final primaryIndex = session.index.isEven ? 0 : 1;
      final primary = '${roots[primaryIndex]}\\pkg\\analyzer';
      final secondary = '${roots[1 - primaryIndex]}\\pkg\\analyzer';
      WindowsFfiAnalyzerProcess? process;
      AnalyzerDaemon? daemon;
      try {
        process = await WindowsFfiAnalyzerProcess.start(sdk, [
          'language-server',
          '--protocol=analyzer',
          '--client-id=dana-latency-research',
        ], workingDirectory: primary);
        daemon = AnalyzerDaemon(
          primary,
          ownedProcessStarter: () async => process!,
        );
        await daemon.start();
        await waitUntilIdle(daemon);
        if (session.mode == 'multi') {
          await daemon.addRoot(secondary);
          await daemon.handle({
            'op': 'check',
            'files': ['$secondary\\$targetFile'],
          });
          await waitUntilIdle(daemon);
        }

        final filePath = '$primary\\$targetFile';
        final directoryPath = '$primary\\$targetDirectory';
        for (var warmup = 0; warmup < 3; warmup++) {
          await daemon.handle({
            'op': 'check',
            'files': [filePath],
          });
          await daemon.handle({
            'op': 'check',
            'files': [directoryPath],
          });
        }
        final fileSamples = <double>[];
        final directorySamples = <double>[];
        for (var i = 0; i < 30; i++) {
          final firstFile = Stopwatch()..start();
          final fileResult = await daemon.handle({
            'op': 'check',
            'files': [filePath],
          });
          firstFile.stop();
          if (fileResult['ok'] != true) {
            throw StateError('Single-file check failed: $fileResult');
          }
          final firstDirectory = Stopwatch()..start();
          final directoryResult = await daemon.handle({
            'op': 'check',
            'files': [directoryPath],
          });
          firstDirectory.stop();
          if (directoryResult['ok'] != true ||
              (directoryResult['diagnostics'] as Map).length < 40) {
            throw StateError(
              'Directory check did not cover 40 files: $directoryResult',
            );
          }
          if (i >= 15) {
            fileSamples.add(firstFile.elapsedMicroseconds / 1000);
            directorySamples.add(firstDirectory.elapsedMicroseconds / 1000);
          }
        }
        rows.add({
          'mode': session.mode,
          'session': session.index + 1,
          'primaryRoot': primary,
          'secondaryRoot': session.mode == 'multi' ? secondary : null,
          'fileSamplesMs': fileSamples,
          'directorySamplesMs': directorySamples,
          'verified': true,
        });
        save();
        stdout.writeln(jsonEncode(rows.last));
      } finally {
        if (daemon != null) await daemon.close();
        if (process != null) {
          await process.terminate();
          if (!process.confirmedEmpty) {
            throw StateError('Analyzer Job did not empty');
          }
        }
      }
    }
    report['passed'] = true;
  } catch (error, stack) {
    report['error'] = '$error';
    report['stack'] = '$stack';
    rethrow;
  } finally {
    for (final path in worktreePaths.reversed) {
      final result = await Process.run('git', [
        '-C',
        source,
        'worktree',
        'remove',
        path,
      ]);
      if (result.exitCode != 0) {
        report['cleanupError'] = result.stderr.toString();
        report['passed'] = false;
      }
    }
    if (await temp.exists()) await temp.delete(recursive: true);
    final remainingWorktrees = await git(source, [
      'worktree',
      'list',
      '--porcelain',
    ]);
    report['cleanupConfirmed'] = worktreePaths.every(
      (path) => !remainingWorktrees.contains(path.replaceAll('\\', '/')),
    );
    save();
    stdout.writeln('Report: ${reportFile.path}; passed=${report['passed']}');
  }
}
