import 'dart:async';
import 'dart:io';

import 'worktree_native_worker_adapter.dart';

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-native-timeout-');
  var timedOutAndCleaned = false;
  try {
    final worker = await NativeModelWorker.start(
      fixture,
      readyTimeout: const Duration(milliseconds: 50),
      readyDelayMs: 500,
    );
    await worker.close();
  } on TimeoutException {
    // An ordinary timeout is rethrown only after tree-stopped(active=0) and owner
    // exit; otherwise start must throw ModelStartupCleanupUnconfirmed instead.
    timedOutAndCleaned = true;
  }
  if (!timedOutAndCleaned) throw StateError('Injected timeout not observed');
  final replacement = await NativeModelWorker.start(fixture);
  await replacement.close();
  if (!replacement.confirmedEmpty) throw StateError('Replacement Job survived');
  print(
    'PASS delayed readiness timeout confirms Job zero; replacement closes; ${fixture.path}',
  );
}
