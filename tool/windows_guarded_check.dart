// Run one research/product script inside a bounded, owned Windows process tree.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.isEmpty) {
    throw ArgumentError('Supply a Dart check script');
  }
  final output = await Directory.systemTemp.createTemp('dana-win-check-');
  final sampler = WindowsSystemMemorySampler();
  final initial = sampler.sample();
  final report = <String, Object?>{
    'sdk': Platform.version,
    'script': args.first,
    'directory': output.path,
    'initialMemory': initial?.toJson(),
    'startupRequiredMiB': 5120,
    'reserveMiB': 4096,
    'peakLimitMiB': 4096,
  };
  WindowsFfiAnalyzerProcess? owner;
  Timer? guard;
  Object? failure;
  final samples = <Map<String, Object?>>[];
  try {
    if (initial == null ||
        !initial.freshAt(DateTime.now().toUtc()) ||
        initial.availablePhysicalBytes < 5120 * bytesPerMiB ||
        initial.availableCommitBytes < 5120 * bytesPerMiB) {
      report['skipped'] = 'startup admission';
      exitCode = 2;
      return;
    }
    owner = await WindowsFfiAnalyzerProcess.start(
      Platform.resolvedExecutable,
      [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        args.first,
        '--probe',
        output.path,
        ...args.skip(1),
      ],
      workingDirectory: Directory.current.path,
      environment: {
        'DANA_GLOBAL_STATE_DIR': '${output.path}/s',
        'DANA_GLOBAL_BUDGET': '1',
        'DANA_GLOBAL_RESERVE_MIB': '4096',
        'DANA_GLOBAL_STARTUP_MIB': '1024',
        'DANA_GLOBAL_COOLDOWN_MS': '0',
        'DANA_GLOBAL_IDLE_SECONDS': '300',
        'DANA_ANALYSIS_TIMEOUT_SECONDS': '150',
        'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
        'DASH__SUPPRESS_ANALYTICS': 'true',
        'DANA_PROBE_PLUGIN_LOG': '${output.path}/plugin-start.jsonl',
      },
    );
    final owned = owner;
    final lines = owned.stdout.transform(utf8.decoder).join();
    final errors = owned.stderr.transform(utf8.decoder).join();
    void sample() {
      if (failure != null) return;
      try {
        final memory = sampler.sample();
        final tree = owned.sampleResources();
        samples.add({'system': memory?.toJson(), 'tree': tree});
        if (memory == null ||
            !memory.freshAt(DateTime.now().toUtc()) ||
            memory.availablePhysicalBytes < 4096 * bytesPerMiB ||
            memory.availableCommitBytes < 4096 * bytesPerMiB ||
            tree['peakPrivateMiB'] is! num ||
            (tree['peakPrivateMiB'] as num) > 4096) {
          throw StateError('Runtime memory protection');
        }
      } catch (error) {
        failure = error;
        owned.terminate().ignore();
      }
    }

    guard = Timer.periodic(const Duration(milliseconds: 250), (_) => sample());
    sample();
    report['exitCode'] = await owned.exitCode.timeout(
      const Duration(minutes: 10),
    );
    guard.cancel();
    await owned.terminate();
    report['stdout'] = await lines;
    report['stderr'] = await errors;
    final result = File('${output.path}/worker-results.json');
    if (await result.exists()) {
      report['workerResult'] = jsonDecode(await result.readAsString());
    }
    if (report['exitCode'] != 0) throw StateError('Windows check failed');
  } catch (error, stack) {
    failure ??= error;
    report['stack'] = '$stack';
  } finally {
    guard?.cancel();
    try {
      await owner?.terminate();
    } catch (error) {
      failure ??= error;
    }
    report['jobEmpty'] = owner?.confirmedEmpty;
    report['failure'] = failure?.toString();
    report['samples'] = samples;
    await File(
      '${output.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('results: ${output.path}/results.json');
    if (failure != null) exitCode = 1;
  }
}
