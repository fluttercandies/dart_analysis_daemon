import 'system_memory.dart';

/// Single-worker admission policy. These are soft reserves, not a memory cap.
class GlobalBudgetPolicy {
  GlobalBudgetPolicy({
    this.reserveBytes,
    this.startupBytes = 512 * bytesPerMiB,
    this.recoveryBytes = 256 * bytesPerMiB,
    this.queueTimeout = const Duration(seconds: 120),
    this.idleTimeout = const Duration(minutes: 5),
    this.cooldown = const Duration(seconds: 2),
    this.ignoreWarnPressure = false,
  }) {
    if ((reserveBytes != null && reserveBytes! <= 0) ||
        startupBytes < 0 ||
        recoveryBytes < 0 ||
        queueTimeout <= Duration.zero ||
        idleTimeout < Duration.zero ||
        cooldown < Duration.zero) {
      throw ArgumentError('Invalid global memory budget');
    }
  }
  final int? reserveBytes;
  final int startupBytes;
  final int recoveryBytes;
  final Duration queueTimeout;
  final Duration idleTimeout;
  final Duration cooldown;

  /// The multi-root pool may ignore macOS warn pressure when physical
  /// headroom is still sufficient. Global single-worker budget keeps this off.
  final bool ignoreWarnPressure;

  factory GlobalBudgetPolicy.fromEnvironment(
    Map<String, String> env, {
    bool ignoreWarnPressure = false,
  }) {
    int value(String name, int fallback, {bool positive = false}) {
      final text = env[name];
      if (text == null) return fallback;
      final parsed = int.tryParse(text);
      if (parsed == null || parsed < (positive ? 1 : 0) || parsed > 1048576) {
        throw FormatException('Invalid $name: $text');
      }
      return parsed;
    }

    return GlobalBudgetPolicy(
      reserveBytes:
          env.containsKey('DANA_GLOBAL_RESERVE_MIB')
              ? value('DANA_GLOBAL_RESERVE_MIB', 0, positive: true) *
                  bytesPerMiB
              : null,
      startupBytes: value('DANA_GLOBAL_STARTUP_MIB', 512) * bytesPerMiB,
      recoveryBytes: value('DANA_GLOBAL_RECOVERY_MIB', 256) * bytesPerMiB,
      queueTimeout: Duration(
        seconds: value(
          'DANA_GLOBAL_QUEUE_TIMEOUT_SECONDS',
          120,
          positive: true,
        ),
      ),
      idleTimeout: Duration(seconds: value('DANA_GLOBAL_IDLE_SECONDS', 300)),
      cooldown: Duration(milliseconds: value('DANA_GLOBAL_COOLDOWN_MS', 2000)),
      ignoreWarnPressure: ignoreWarnPressure,
    );
  }

  int effectiveReserve(SystemMemorySnapshot sample) =>
      reserveBytes ??
      (sample.totalPhysicalBytes * 15 ~/ 100).clamp(
        1024 * bytesPerMiB,
        4096 * bytesPerMiB,
      );

  String? waitingReason(
    SystemMemorySnapshot? sample, {
    required bool starting,
    required bool recovering,
    required DateTime now,
  }) {
    if (sample == null || !sample.freshAt(now)) {
      return 'memory-sample-unavailable';
    }
    final requiredBytes =
        effectiveReserve(sample) +
        (starting ? startupBytes : 0) +
        (recovering ? recoveryBytes : 0);
    if (sample.availablePhysicalBytes < requiredBytes) {
      return 'physical-reserve';
    }
    if (sample.availableCommitBytes < requiredBytes &&
        !(ignoreWarnPressure &&
            sample.pressureLevel != null &&
            sample.pressureLevel! >= 2 &&
            sample.pressureLevel! < 4)) {
      return 'commit-reserve';
    }
    return null;
  }

  Map<String, Object?> toJson(SystemMemorySnapshot? sample) => {
    'maxWorkers': 1,
    'reserveMiB':
        sample == null
            ? reserveBytes == null
                ? null
                : reserveBytes! / bytesPerMiB
            : effectiveReserve(sample) / bytesPerMiB,
    'startupMiB': startupBytes / bytesPerMiB,
    'recoveryMiB': recoveryBytes / bytesPerMiB,
    'queueTimeoutSeconds': queueTimeout.inSeconds,
    'idleTimeoutSeconds': idleTimeout.inSeconds,
    'cooldownMs': cooldown.inMilliseconds,
    'ignoreWarnPressure': ignoreWarnPressure,
    'hardMemoryCap': false,
  };
}
