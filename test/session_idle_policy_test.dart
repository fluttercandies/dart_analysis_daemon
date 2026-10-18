import 'dart:async';

import 'package:dart_analysis_daemon/src/session_idle_policy.dart';
import 'package:test/test.dart';

void main() {
  const timeout = Duration(milliseconds: 25);
  Future<void> pastTimeout() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  test('validates configuration instead of silently disabling reclamation', () {
    expect(parseSessionIdleTimeout(null), Duration.zero);
    expect(parseSessionIdleTimeout('0'), Duration.zero);
    expect(parseSessionIdleTimeout('120'), const Duration(seconds: 120));
    for (final value in ['-1', 'abc', '', '1.5', '2147484']) {
      expect(() => parseSessionIdleTimeout(value), throwsFormatException);
    }
    expect(
      () => SessionIdlePolicy(
        timeout: const Duration(seconds: -1),
        onIdle: () {},
      ),
      throwsArgumentError,
    );
  });

  test('disabled policy keeps a disconnected session resident', () async {
    var reclaimed = false;
    final policy = SessionIdlePolicy(
      timeout: Duration.zero,
      onIdle: () => reclaimed = true,
    );
    addTearDown(policy.close);
    policy.clientConnected();
    policy.clientDisconnected();
    await pastTimeout();
    expect(reclaimed, false);
  });

  test('unused session is reclaimed once', () async {
    var calls = 0;
    final done = Completer<void>();
    final policy = SessionIdlePolicy(
      timeout: timeout,
      onIdle: () {
        calls++;
        done.complete();
      },
    );
    addTearDown(policy.close);
    await done.future.timeout(const Duration(seconds: 2));
    policy.clientConnected();
    policy.clientDisconnected();
    await pastTimeout();
    expect(calls, 1);
  });

  test('all connected clients hold the session and overlay state', () async {
    var reclaimed = false;
    final policy = SessionIdlePolicy(
      timeout: timeout,
      onIdle: () => reclaimed = true,
    );
    addTearDown(policy.close);
    policy.clientConnected();
    policy.clientConnected();
    policy.clientDisconnected();
    await pastTimeout();
    expect(reclaimed, false);
    policy.clientDisconnected();
    await pastTimeout();
    expect(reclaimed, true);
  });

  test('disconnected callers retain queued and active exchanges', () async {
    var reclaimed = false;
    final policy = SessionIdlePolicy(
      timeout: timeout,
      onIdle: () => reclaimed = true,
    );
    addTearDown(policy.close);
    policy.clientConnected();
    policy.requestQueued();
    policy.requestQueued();
    policy.clientDisconnected();
    await pastTimeout();
    expect(reclaimed, false);
    policy.requestFinished();
    await pastTimeout();
    expect(reclaimed, false);
    policy.requestFinished();
    await pastTimeout();
    expect(reclaimed, true);
  });

  test('reconnection cancels an armed timer', () async {
    var reclaimed = false;
    final policy = SessionIdlePolicy(
      timeout: timeout,
      onIdle: () => reclaimed = true,
    );
    addTearDown(policy.close);
    policy.clientConnected();
    policy.clientDisconnected();
    policy.clientConnected();
    await pastTimeout();
    expect(reclaimed, false);
    policy.clientDisconnected();
    await pastTimeout();
    expect(reclaimed, true);
  });

  test('explicit shutdown cancels pending reclamation', () async {
    var reclaimed = false;
    final policy = SessionIdlePolicy(
      timeout: timeout,
      onIdle: () => reclaimed = true,
    );
    policy.close();
    policy.clientConnected();
    policy.clientDisconnected();
    await pastTimeout();
    expect(reclaimed, false);
  });
}
