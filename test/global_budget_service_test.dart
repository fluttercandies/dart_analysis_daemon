import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/global_analyzer_pool.dart';
import 'package:dart_analysis_daemon/src/global_budget_policy.dart';
import 'package:dart_analysis_daemon/src/global_budget_service.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:test/test.dart';

class _Worker extends AnalyzerDaemon {
  _Worker(super.root, this.events, this.onCheck);
  final List<String> events;
  final Future<void> Function() onCheck;
  @override
  Future<void> start() async {
    events.add('start:$root');
  }

  @override
  Future<Map<String, Object?>> handle(Map<String, Object?> command) async {
    events.add('check:$root');
    await onCheck();
    return {'ok': true, 'files': command['files']};
  }

  @override
  Future<void> close() async {
    events.add('close:$root');
  }
}

void main() {
  if (!Platform.isWindows) return;
  test(
    'global wire authenticates, validates disk scope, reuses roots, and confirms stop',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dana-budget-wire-',
      );
      final a = await Directory('${directory.path}/A').create();
      final b = await Directory('${directory.path}/B').create();
      final afile = await File(
        '${a.path}/file.dart',
      ).writeAsString('int a = 1;');
      final bfile = await File(
        '${b.path}/file.dart',
      ).writeAsString('int b = 2;');
      final events = <String>[];
      var editDuringCheck = false;
      var addDuringCheck = false;
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory:
            () => SystemMemorySnapshot(
              totalPhysicalBytes: 16384 * bytesPerMiB,
              availablePhysicalBytes: 8192 * bytesPerMiB,
              commitLimitBytes: 32768 * bytesPerMiB,
              availableCommitBytes: 8192 * bytesPerMiB,
            ),
        createWorker:
            (root) => _Worker(root, events, () async {
              if (editDuringCheck) await bfile.writeAsString('int b = 3;');
              if (addDuringCheck) {
                await File('${b.path}/added.dart').writeAsString('int c = 4;');
              }
            }),
      );
      final serving = serveGlobalBudget(directory: directory, pool: pool);
      final record = File('${directory.path}/endpoint.json');
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!await record.exists()) {
          if (DateTime.now().isAfter(deadline)) fail('No global endpoint');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final metadata = jsonDecode(await record.readAsString()) as Map;
        final wrong = await Socket.connect(
          InternetAddress.loopbackIPv4,
          metadata['port'] as int,
        );
        wrong.writeln(
          jsonEncode({'protocol': 1, 'token': 'wrong', 'op': 'status'}),
        );
        await wrong.flush();
        final denied =
            jsonDecode(
                  await wrong
                      .cast<List<int>>()
                      .transform(utf8.decoder)
                      .transform(const LineSplitter())
                      .first,
                )
                as Map;
        expect(denied['ok'], false);
        wrong.destroy();
        Future<Map<String, Object?>> check(Directory root, Object file) =>
            globalBudgetRequest(
              {
                'op': 'check',
                'root': root.path,
                'command': {
                  'op': 'check',
                  'files': [file],
                },
              },
              autoStart: false,
              directory: directory,
            );
        expect((await check(a, afile.path))['ok'], true);
        expect((await check(a, afile.path))['workerGeneration'], 1);
        final expanded = await check(a, a.path);
        expect(expanded['targetVersionChecked'], true);
        expect(expanded['dependenciesFrozen'], false);
        expect(expanded['files'], [await afile.resolveSymbolicLinks()]);
        expect((await check(a, bfile.path))['ok'], false);
        expect(
          (await check(a, {'path': afile.path, 'content': 'overlay'}))['ok'],
          false,
        );
        expect((await check(b, bfile.path))['workerGeneration'], 2);
        final status = await globalBudgetRequest(
          {'op': 'status'},
          autoStart: false,
          directory: directory,
        );
        expect(status['workerCount'], 1);
        expect(status['starts'], 2);
        final options = await File(
          '${b.path}/analysis_options.yaml',
        ).writeAsString('analyzer: {}\n');
        expect((await check(b, bfile.path))['workerGeneration'], 3);
        final replacement = await File(
          '${b.path}/options.new',
        ).writeAsString('analyzer: {}\n');
        await options.rename('${b.path}/options.old');
        await replacement.rename(options.path);
        expect((await check(b, bfile.path))['workerGeneration'], 4);
        await File(
          '${a.path}/analysis_options.yaml',
        ).writeAsString('x' * (4 * 1024 * 1024 + 1));
        expect((await check(a, afile.path))['ok'], false);
        expect(pool.status['workerCount'], 1);
        editDuringCheck = true;
        final changed = await check(b, bfile.path);
        expect(changed['ok'], false);
        expect(changed['error'], contains('Target changed'));
        expect(pool.status['workerCount'], 0);
        editDuringCheck = false;
        addDuringCheck = true;
        final added = await check(b, b.path);
        expect(added['ok'], false);
        expect(added['error'], contains('Target directory changed'));
        final stopped = await globalBudgetRequest(
          {'op': 'stop'},
          autoStart: false,
          directory: directory,
        );
        expect(stopped['shutdownComplete'], true);
        await serving.timeout(const Duration(seconds: 5));
        expect(await record.exists(), false);
        expect(events.where((event) => event.startsWith('close:')).length, 5);
      } finally {
        if (await record.exists()) {
          await globalBudgetRequest(
            {'op': 'stop'},
            autoStart: false,
            directory: directory,
          );
        }
        await serving;
        await pool.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
