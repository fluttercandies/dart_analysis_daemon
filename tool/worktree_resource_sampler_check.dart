import 'dart:async';
import 'dart:convert';

import 'worktree_resource_sampler.dart';

Future<void> main() async {
  final policy = ResearchMemoryPolicy();
  final cases = <(double?, double?, int?, bool)>[
    (8192, 6144, 0, true),
    (5120, 5120, 2000, true),
    (5119.9, 8192, 0, false),
    (8192, 5119.9, 0, false),
    (null, 8192, 0, false),
    (8192, null, 0, false),
    (double.nan, 8192, 0, false),
    (8192, double.infinity, 0, false),
    (-1, 8192, 0, false),
    (8192, 8192, null, false),
    (8192, 8192, 2001, false),
    (8192, 8192, -1, false),
  ];
  for (final (physical, commit, age, expected) in cases) {
    if (policy.admits(physical, commit, age) != expected) {
      throw StateError('Admission mismatch: $physical $commit $age');
    }
  }
  for (final invalid in [-1.0, double.nan, double.infinity]) {
    var rejected = false;
    try {
      ResearchMemoryPolicy(reserveMiB: invalid);
    } on ArgumentError {
      rejected = true;
    }
    if (!rejected) throw StateError('Invalid threshold accepted');
  }
  final sampler = await ResearchResourceSampler.start();
  try {
    if (sampler.physicalMiB == null || sampler.commitMiB == null) {
      throw StateError('Missing real sample');
    }
    final first = sampler.sampledAt;
    final timer = Stopwatch()..start();
    while (sampler.sampledAt == first) {
      if (timer.elapsed > const Duration(seconds: 5)) {
        throw TimeoutException('No refresh');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    print(
      jsonEncode({
        'policyCases': cases.length + 3,
        'realSample': sampler.status,
      }),
    );
  } finally {
    await sampler.close();
  }
  if (sampler.allowed) throw StateError('Dead sampler admitted startup');
  print(
    'PASS 15 policy cases, real counters refresh, dead sampler fails closed',
  );
}
