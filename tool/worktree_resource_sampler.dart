// Research-only system admission. Quantities are MiB; no analyzer is launched.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ResearchMemoryPolicy {
  ResearchMemoryPolicy({this.reserveMiB = 4096, this.startupMiB = 1024}) {
    if (!reserveMiB.isFinite ||
        !startupMiB.isFinite ||
        reserveMiB < 0 ||
        startupMiB < 0) {
      throw ArgumentError('Invalid research thresholds');
    }
  }
  final double reserveMiB;
  final double startupMiB;
  bool admits(double? physical, double? commit, int? ageMs) =>
      physical != null &&
      commit != null &&
      ageMs != null &&
      physical.isFinite &&
      commit.isFinite &&
      physical >= reserveMiB + startupMiB &&
      commit >= reserveMiB + startupMiB &&
      ageMs >= 0 &&
      ageMs <= 2000;
}

class ResearchResourceSampler {
  ResearchResourceSampler._(this.process);
  final Process process;
  final policy = ResearchMemoryPolicy();
  final clock = Stopwatch()..start();
  final first = Completer<void>();
  late final StreamSubscription<String> subscription;
  double? physicalMiB;
  double? commitMiB;
  int? sampledAt;
  bool exited = false;
  int? get ageMs =>
      sampledAt == null ? null : clock.elapsedMilliseconds - sampledAt!;
  bool get allowed => !exited && policy.admits(physicalMiB, commitMiB, ageMs);
  Map<String, Object?> get status => {
    'physicalMiB': physicalMiB,
    'commitMiB': commitMiB,
    'ageMs': ageMs,
    'allowed': allowed,
    'exited': exited,
    'requiredMiB': policy.reserveMiB + policy.startupMiB,
  };

  static Future<ResearchResourceSampler> start() async {
    final script = File.fromUri(
      Platform.script.resolve(
        '../../benchmarks/minimal-plugin/worktree-resource-sampler.ps1',
      ),
    );
    final process = await Process.start(
      '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoProfile', '-NonInteractive', '-File', script.path],
    );
    final sampler = ResearchResourceSampler._(process);
    unawaited(process.stderr.drain<void>());
    sampler.subscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final value = jsonDecode(line) as Map;
              sampler.physicalMiB = (value['physicalMiB'] as num?)?.toDouble();
              sampler.commitMiB = (value['commitMiB'] as num?)?.toDouble();
              sampler.sampledAt = sampler.clock.elapsedMilliseconds;
              if (!sampler.first.isCompleted) sampler.first.complete();
            } catch (_) {
              sampler.sampledAt = null;
            }
          },
          onError: (Object _) {
            sampler.sampledAt = null;
          },
        );
    unawaited(
      process.exitCode.then((_) {
        sampler.exited = true;
      }),
    );
    try {
      await sampler.first.future.timeout(const Duration(seconds: 10));
      return sampler;
    } catch (_) {
      await sampler.close();
      rethrow;
    }
  }

  Future<void> close() async {
    process.kill(); // Only this read-only helper; it has no child processes.
    await subscription.cancel();
    await process.exitCode.timeout(const Duration(seconds: 10));
    exited = true;
  }
}
