import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/session_server.dart';

/// A client for one root-scoped `dart_analysis_daemon` session.
class SessionClient {
  SessionClient._(this.root, this._socket, this._token)
    : _lines = StreamIterator(
        _socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  /// Connects to a root session, starting one when [autoStart] is true.
  static Future<SessionClient> connect(
    String root, {
    bool autoStart = true,
  }) async {
    final canonicalRoot = Directory(root).resolveSymbolicLinksSync();
    final connection = await connectOrStartSession(
      canonicalRoot,
      endpointFile(canonicalRoot),
      autoStart: autoStart,
    );
    if (connection == null) {
      throw StateError('No compatible analyzer session for $canonicalRoot');
    }
    return SessionClient._(canonicalRoot, connection.$1, connection.$2);
  }

  final String root;
  final Socket _socket;
  final String _token;
  final StreamIterator<String> _lines;
  bool _closed = false;

  Future<Map<String, Object?>> checkFiles(
    List<String> files, {
    Map<String, String> overlays = const {},
  }) => _send({
    'op': 'check',
    'files': [
      for (final path in files)
        overlays.containsKey(path)
            ? {'path': path, 'content': overlays[path]}
            : path,
    ],
  });

  Future<Map<String, Object?>> clearOverlays(List<String> files) =>
      _send({'op': 'clearContent', 'files': files});

  Future<Map<String, Object?>> fullCheck() => _send({'op': 'fullCheck'});

  Future<Map<String, Object?>> status() => _send({'op': 'status'});

  /// Waits for server-side cleanup. A failed close returns `ok: false`.
  /// Analyzer process exit does not prove that arbitrary descendants exited;
  /// product process-tree ownership is still platform dependent.
  Future<Map<String, Object?>> shutdown() async {
    final response = await _send({'op': 'shutdown'});
    final endpoint = endpointFile(root);
    for (var attempt = 0; attempt < 60; attempt++) {
      if (!await endpoint.exists()) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await close();
    return response;
  }

  Future<Map<String, Object?>> _send(Map<String, Object?> command) async {
    if (_closed) throw StateError('Session client is closed');
    _socket.writeln(jsonEncode({...command, 'token': _token}));
    await _socket.flush();
    if (!await _lines.moveNext()) throw StateError('Session disconnected');
    final decoded = jsonDecode(_lines.current);
    if (decoded is! Map) throw StateError('Invalid session response');
    return Map<String, Object?>.from(decoded);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _lines.cancel();
    _socket.destroy();
  }
}
