import 'package:dart_analysis_daemon/src/global_budget_policy.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:test/test.dart';

void main() {
  const total = 24576 * bytesPerMiB;
  const available = 8000 * bytesPerMiB;
  final now = DateTime.utc(2026, 1, 1);
  final policy = GlobalBudgetPolicy(reserveBytes: 4000 * bytesPerMiB);

  SystemMemorySnapshot snap(int? level) => macSnapshot(
    totalPhysicalBytes: total,
    availablePhysicalBytes: available,
    pressureLevel: level,
    sampledAt: now,
  );

  test('normal pressure mirrors physical availability into commit', () {
    final s = snap(1);
    expect(s.availableCommitBytes, available);
    expect(s.commitLimitBytes, total);
    expect(
      policy.waitingReason(s, starting: true, recovering: false, now: now),
      isNull,
    );
  });

  test('warn pressure remains a commit-pressure signal', () {
    final s = snap(2);
    expect(s.availablePhysicalBytes, available);
    expect(s.availableCommitBytes, 0);
    expect(
      policy.waitingReason(s, starting: true, recovering: false, now: now),
      'commit-reserve',
    );
  });

  test('critical pressure leaves no commit and refuses admission', () {
    final s = snap(4);
    expect(s.availablePhysicalBytes, available);
    expect(s.availableCommitBytes, 0);
    expect(s.freshAt(now), isTrue);
    expect(
      policy.waitingReason(s, starting: true, recovering: false, now: now),
      'commit-reserve',
    );
  });

  test('an unknown pressure level does not change the physical figure', () {
    expect(snap(null).availableCommitBytes, available);
  });

  test('multi-root policy ignores warn for admission and reclamation', () {
    final advisory = GlobalBudgetPolicy(
      reserveBytes: 4000 * bytesPerMiB,
      ignoreWarnPressure: true,
    );
    expect(
      advisory.waitingReason(
        snap(2),
        starting: true,
        recovering: false,
        now: now,
      ),
      isNull,
    );
    expect(
      advisory.waitingReason(
        snap(2),
        starting: false,
        recovering: false,
        now: now,
      ),
      isNull,
    );
    expect(
      advisory.waitingReason(
        snap(4),
        starting: true,
        recovering: false,
        now: now,
      ),
      'commit-reserve',
    );
  });
}
