// Research-only authenticated loopback transport for a synthetic overlay worker.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

String overlayDigest(Map<String, String> files) {
  final keys = files.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(jsonEncode({for (final key in keys) key: files[key]})),
      )
      .toString();
}

Future<Map> readOverlayFrame(Socket socket) async {
  final bytes = <int>[];
  await for (final chunk in socket) {
    for (final byte in chunk) {
      if (byte == 10) return jsonDecode(utf8.decode(bytes)) as Map;
      if (bytes.length >= 2 * 1024 * 1024) {
        throw StateError('Overlay frame limit');
      }
      bytes.add(byte);
    }
  }
  throw StateError('Incomplete overlay frame');
}

Future<ServerSocket> startOverlayWorker(String token) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  var files = <String, String>{};
  String? scope;
  var generation = 0;
  var serial = 0;
  var connections = 0;
  var applying = false;
  server.listen((socket) async {
    if (++connections > 4) {
      connections--;
      socket.destroy();
      return;
    }
    var ownsApply = false;
    try {
      final input = await readOverlayFrame(
        socket,
      ).timeout(const Duration(seconds: 5));
      if (input['token'] != token || applying) {
        throw StateError('Overlay auth or concurrent apply');
      }
      final next = (input['files'] as Map).cast<String, String>();
      final removes = (input['removes'] as List).cast<String>();
      final nextScope = input['scope'] as String;
      final nextGeneration = input['generation'] as int;
      final nextSerial = input['serial'] as int;
      final delay = input['delayMs'] as int;
      if (next.length > 128 ||
          removes.length > 128 ||
          (scope != null && scope != nextScope) ||
          nextGeneration < generation ||
          (nextGeneration == generation && nextSerial <= serial) ||
          delay < 0 ||
          delay > 2000) {
        throw StateError('Invalid replay');
      }
      final candidate = Map<String, String>.of(files);
      for (final path in removes) {
        candidate.remove(path);
      }
      candidate.addAll(next);
      if (candidate.length > 128 ||
          candidate.values.fold<int>(0, (n, v) => n + utf8.encode(v).length) >
              256 * 1024) {
        throw StateError('Overlay state limit');
      }
      applying = ownsApply = true;
      // Apply before delaying the acknowledgement to exercise stale acks.
      files = candidate;
      scope = nextScope;
      generation = nextGeneration;
      serial = nextSerial;
      await Future<void>.delayed(Duration(milliseconds: delay));
      socket.writeln(
        jsonEncode({
          'ok': true,
          'generation': generation,
          'revision': input['revision'],
          'serial': serial,
          'digest': overlayDigest(files),
          'fileCount': files.length,
        }),
      );
      await socket.flush().timeout(const Duration(seconds: 2));
    } catch (error) {
      try {
        socket.writeln(jsonEncode({'ok': false}));
        await socket.flush().timeout(const Duration(seconds: 2));
      } catch (_) {}
    } finally {
      if (ownsApply) applying = false;
      connections--;
      socket.destroy();
    }
  });
  return server;
}

Future<Map> sendOverlayFrame(int port, Map<String, Object?> input) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 2),
  );
  try {
    Future<Map> exchange() async {
      socket.writeln(jsonEncode(input));
      await socket.flush();
      return readOverlayFrame(socket);
    }

    // Include flush in the bound: a stalled worker must not hold a lease forever.
    return await exchange().timeout(const Duration(seconds: 5));
  } finally {
    socket.destroy();
  }
}
