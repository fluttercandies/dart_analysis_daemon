import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_overlay_transport.dart';

Future<void> main() async {
  final server = await startOverlayWorker('test-secret');
  final results = <Map>[];
  void check(bool condition) {
    if (!condition) throw StateError('Transport invariant');
  }

  Future<void> run(String name, Future<void> Function() body) async {
    await body().timeout(const Duration(seconds: 12));
    results.add({'name': name, 'passed': true});
    print('PASS $name');
  }

  Future<Map> send({
    String token = 'test-secret',
    String scope = 'root',
    int serial = 1,
    Map<String, String> files = const {},
    List<String> removes = const [],
  }) => sendOverlayFrame(server.port, {
    'token': token,
    'scope': scope,
    'generation': 1,
    'revision': serial,
    'serial': serial,
    'files': files,
    'removes': removes,
    'delayMs': 0,
  });
  try {
    await run('bad authentication cannot apply content', () async {
      check(
        (await send(token: 'wrong', files: {'x': 'poison'}))['ok'] == false,
      );
      final response = await send(files: {'a': 'one'});
      check(response['ok'] == true && response['fileCount'] == 1);
    });
    await run(
      'stale replay and foreign scope fail without changing applied state',
      () async {
        check((await send(serial: 1, files: {'x': 'stale'}))['ok'] == false);
        check(
          (await send(
                scope: 'other',
                serial: 2,
                files: {'x': 'foreign'},
              ))['ok'] ==
              false,
        );
        final response = await send(serial: 2, removes: ['a']);
        check(
          response['ok'] == true &&
              response['fileCount'] == 0 &&
              response['digest'] == overlayDigest({}),
        );
      },
    );
    await run(
      'malformed and oversized frames close without breaking later connections',
      () async {
        for (final bytes in [
          utf8.encode('not-json\n'),
          List<int>.filled(2 * 1024 * 1024 + 1, 120),
        ]) {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            server.port,
          );
          try {
            final reply = readOverlayFrame(socket);
            socket.add(bytes);
            await socket.flush();
            check(
              (await reply.timeout(const Duration(seconds: 5)))['ok'] == false,
            );
          } finally {
            socket.destroy();
          }
        }
        check((await send(serial: 3))['ok'] == true);
      },
    );
    await run('stalled peer has bounded roundtrip including writes', () async {
      final stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      stalled.listen(peers.add);
      final watch = Stopwatch()..start();
      var timedOut = false;
      try {
        await sendOverlayFrame(stalled.port, {
          'padding': List.filled(2 * 1024 * 1024, 'x').join(),
        });
      } on TimeoutException {
        timedOut = true;
      } finally {
        for (final peer in peers) {
          peer.destroy();
        }
        await stalled.close();
      }
      check(timedOut && watch.elapsed < const Duration(seconds: 8));
    });
    print(
      jsonEncode({
        'results': results,
        'allPassed': true,
        'syntheticTransportOnly': true,
      }),
    );
  } finally {
    await server.close();
  }
}
