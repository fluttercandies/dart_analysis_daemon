import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_protocol_output.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final held = Completer<void>();
  var closes = 0;
  final capped = ResearchOutputBuffer(
    limit: 8,
    writeBytes: (_) => held.future,
    onClose: () {
      closes++;
    },
  );
  capped.add([1, 2, 3, 4]);
  capped.add([5, 6, 7, 8]);
  check(capped.pendingBytes == 8, 'Exact output budget rejected');
  capped.add([9]);
  check(
    capped.closed && closes == 1 && capped.pendingBytes == 0,
    'Overflow retained memory or failed to close',
  );
  held.complete();
  await Future<void>.delayed(Duration.zero);
  check(
    capped.pendingBytes == 0 && closes == 1,
    'Late write corrupted closed buffer',
  );
  print('PASS exact byte budget, overflow close, late write completion');

  final timed = ResearchOutputBuffer(
    writeBytes: (_) => Completer<void>().future,
    timeout: const Duration(milliseconds: 50),
    onClose: () {
      closes++;
    },
  );
  timed.add([1]);
  await timed.drained.timeout(const Duration(seconds: 1));
  check(
    timed.closed && timed.error is TimeoutException && closes == 2,
    'Blocked output did not close',
  );
  print('PASS blocked writer timeout releases buffer');

  final order = <int>[];
  var simultaneous = 0;
  final healthy = ResearchOutputBuffer(
    writeBytes: (bytes) async {
      simultaneous++;
      check(simultaneous == 1, 'Concurrent socket writes');
      await Future<void>.delayed(Duration.zero);
      order.add(bytes.single);
      simultaneous--;
    },
    onClose: () {
      throw StateError('Healthy writer closed');
    },
  );
  for (var i = 0; i < 100; i++) {
    healthy.add([i]);
  }
  await healthy.drained;
  check(
    order.length == 100 &&
        order.asMap().entries.every((e) => e.key == e.value) &&
        healthy.pendingBytes == 0 &&
        !healthy.closed,
    'Output ordering or drain failed',
  );
  print('PASS one hundred ordered responses use one writer');

  final broken = ResearchOutputBuffer(
    writeBytes: (_) async {
      throw StateError('injected write failure');
    },
    onClose: () {
      closes++;
    },
  );
  broken.add([1]);
  await broken.drained;
  check(
    broken.closed && broken.error is StateError && closes == 3,
    'Failed writer did not close',
  );
  print('PASS writer error closes once');
  final fixture = await Directory.systemTemp.createTemp('dana-output-buffer-');
  final report = {'groups': 4, 'allPassed': true, 'fixture': fixture.path};
  await File('${fixture.path}/results.json').writeAsString(jsonEncode(report));
  print(jsonEncode(report));
}
